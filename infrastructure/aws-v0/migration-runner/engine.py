"""Migration engine with a closed statement contract and explicit transactions.

Transport supplies begin/execute/commit/rollback. No connection is opened on import.
An ambiguous commit stops the batch even when later state proves that it committed.
"""
import json
import re
import uuid
from contract import (BOOTSTRAP, DATABASE, DB_ROLE, HASHES, SQL, GateError,
                      canonical, fingerprint, object_map, require)


class Engine:
    def __init__(self, package, transport):
        self.package, self.transport = package, transport
        self.events = []
        self.run_id = str(uuid.uuid4())
        self.active = set()
        self.uncertain = set()
        self.rollback_attempted = set()
        self.catalog_difference = []

    def execute(self, tx, name, params=None):
        require(tx in self.active, 'TRANSACTION_NOT_OWNED')
        return self.transport.execute(tx, SQL[name], params or [])

    @staticmethod
    def flag(rows, field):
        require(isinstance(rows,list) and len(rows)==1 and set(rows[0])=={field} and type(rows[0][field]) is bool,
                'BOOLEAN_RESPONSE_INVALID')
        return rows[0][field]

    def close(self, tx, commit=False):
        require(tx in self.active, 'TRANSACTION_NOT_OWNED')
        if commit:
            self.transport.commit(tx)
        else:
            require(tx not in self.rollback_attempted, 'ROLLBACK_ALREADY_ATTEMPTED')
            self.rollback_attempted.add(tx)
            self.transport.rollback(tx)
        self.active.remove(tx)

    def rollback_known(self, tx):
        if tx not in self.active or tx in self.uncertain or tx in self.rollback_attempted: return
        try:
            self.close(tx)
            self.events.append({'operation':'rollback','status':'ACKNOWLEDGED'})
        except Exception:
            self.events.append({'operation':'rollback','status':'UNKNOWN'})

    def begin(self, read_only=False):
        tx = self.transport.begin()
        require(isinstance(tx,str) and tx and tx not in self.active, 'BEGIN_RESPONSE_INVALID')
        self.active.add(tx)
        try:
            self.execute(tx,'isolation')
            if read_only: self.execute(tx,'readOnly')
            self.execute(tx,'timeout'); self.execute(tx,'lockTimeout')
            identity=self.execute(tx,'identity')
            require(len(identity)==1, 'DATABASE_IDENTITY_INVALID')
            item=identity[0]
            require(item.get('database')==DATABASE and item.get('role')==DB_ROLE and
                    item.get('session_role')==DB_ROLE and str(item.get('version','')).startswith('16.') and
                    item.get('isolation')=='read committed' and item.get('read_only')==('on' if read_only else 'off'),'DATABASE_IDENTITY_MISMATCH')
            require(self.flag(self.execute(tx,'lock'),'acquired'),'MIGRATION_BUSY')
            return tx
        except BaseException:
            self.rollback_known(tx)
            raise

    def check_rows(self, rows):
        require(isinstance(rows,list) and len(rows)<=5,'HISTORY_PREFIX_INVALID')
        for ordinal, row in enumerate(rows,3):
            name=self.package.names[ordinal]
            expected={'ordinal':ordinal,'filename':name,'file_sha256':HASHES[name],
                'plan_sha256':self.package.plan_sha,'before_sha256':self.package.hashes[str(ordinal-1)],
                'after_sha256':self.package.hashes[str(ordinal)]}
            require(isinstance(row,dict) and set(row)==set(expected)|{'run_id','recorded_at'} and
                    all(row[k]==v for k,v in expected.items()),'HISTORY_PREFIX_OR_CHECKSUM_MISMATCH')
            try: uuid.UUID(row['run_id'])
            except (ValueError,TypeError,AttributeError): raise GateError('HISTORY_RUN_ID_INVALID') from None
            require(isinstance(row['recorded_at'],str) and bool(row['recorded_at']),'HISTORY_TIMESTAMP_INVALID')
        return 2+len(rows)

    def compare(self, actual, expected, code):
        if actual != expected:
            self.catalog_difference = sorted(k for k in set(actual)|set(expected) if actual.get(k)!=expected.get(k))[:40]
            raise GateError(code)

    def verify(self, tx):
        require(self.flag(self.execute(tx,'lockHeld'),'held'),'LOCKED_TRANSACTION_REQUIRED')
        control=object_map(self.execute(tx,'historyCatalog'))
        exists=bool(control)
        if exists:
            self.compare(control,self.package.history_contract,'HISTORY_STRUCTURE_OR_PRIVILEGE_DRIFT')
            rows=self.execute(tx,'history')
        else: rows=[]
        tip=self.check_rows(rows)
        catalog=object_map(self.execute(tx,'catalog'))
        self.compare(catalog,self.package.expected[str(tip)],
                     'SCHEMA_HISTORY_MISMATCH' if exists else 'HISTORY_ABSENT_SCHEMA_NOT_BASELINE')
        if tip>=6: require(self.flag(self.execute(tx,'modelOff'),'disabled'),'MODEL_ADMISSION_NOT_DISABLED')
        if tip>=7: require(self.flag(self.execute(tx,'recoveryOff'),'disabled'),'RECOVERY_NOT_DISABLED')
        return {'tip':tip,'historyExists':exists,'history':rows,'catalogSha256':fingerprint(catalog)}

    def inspect(self):
        tx=self.begin(read_only=True)
        try:
            state=self.verify(tx)
            require(not self.flag(self.execute(tx,'busy'),'busy'),'ACTIVE_RESEARCH_OR_SCHEDULER')
            self.close(tx)
            return state
        finally: self.rollback_known(tx)

    def stage(self, ordinal):
        """Prepare one file in one transaction. Caller must explicitly commit."""
        require(type(ordinal) is int and ordinal in range(3,8),'MIGRATION_NOT_IN_PLAN')
        tx=self.begin()
        try:
            # Stabilise participating work before inspecting it. Does not stop a
            # privileged owner issuing unrelated raw DDL; use a maintenance window.
            self.execute(tx,'maintenanceLock')
            require(not self.flag(self.execute(tx,'busy'),'busy'),'ACTIVE_RESEARCH_OR_SCHEDULER')
            state=self.verify(tx)
            if ordinal <= state['tip']:
                self.close(tx)
                return None
            require(ordinal==state['tip']+1,'MIGRATION_PREDECESSOR_MISSING')
            if not state['historyExists']:
                for stmt in BOOTSTRAP: self.transport.execute(tx,stmt,[])
                self.compare(object_map(self.execute(tx,'historyCatalog')),self.package.history_contract,'HISTORY_BOOTSTRAP_MISMATCH')
            for stmt in self.package.bodies[ordinal]: self.transport.execute(tx,stmt,[])
            self.compare(object_map(self.execute(tx,'catalog')),self.package.expected[str(ordinal)],'MIGRATION_POSTCONDITION_MISMATCH')
            name=self.package.names[ordinal]
            record={'ordinal':ordinal,'filename':name,'file_sha256':HASHES[name],
                'plan_sha256':self.package.plan_sha,'before_sha256':self.package.hashes[str(ordinal-1)],
                'after_sha256':self.package.hashes[str(ordinal)],'run_id':self.run_id}
            self.execute(tx,'insertReceipt',[{'name':'receipt','value':{'stringValue':canonical(record)}}])
            require(self.verify(tx)['tip']==ordinal,'POST_RECEIPT_VERIFICATION_FAILED')
            return tx
        except BaseException:
            self.rollback_known(tx)
            raise

    def reconcile(self, ordinal):
        """Fresh locked inspection only; never automatically retries a migration."""
        try:
            state=self.inspect()
            require(state['tip']>=ordinal-1,'RECONCILIATION_HISTORY_REWOUND')
            return 'COMMITTED' if state['tip']>=ordinal else 'NOT_COMMITTED'
        except Exception as exc:
            self.events.append({'operation':'reconcile','status':'UNKNOWN','errorCode':str(exc) if isinstance(exc,GateError) else 'TRANSPORT_ERROR'})
            return 'UNKNOWN'

    def apply_one(self, ordinal):
        tx=self.stage(ordinal)
        if tx is None:
            self.events.append({'ordinal':ordinal,'status':'ALREADY_APPLIED_VERIFIED'})
            return 'ALREADY_APPLIED_VERIFIED'
        # Once a commit is dispatched, no automatic commit retry and no rollback
        # used to infer the commit result. Reconcile using a fresh locked transaction.
        self.uncertain.add(tx)
        try:
            self.close(tx,commit=True)
            self.uncertain.discard(tx)
        except BaseException as exc:
            result=self.reconcile(ordinal)
            if result!='UNKNOWN':
                self.active.discard(tx); self.uncertain.discard(tx)
                self.transport.forget_reconciled(tx)
            self.events.append({'ordinal':ordinal,'status':'COMMIT_RESPONSE_UNCERTAIN','reconciliation':result})
            raise GateError('COMMIT_UNCERTAIN_'+result+'_BATCH_STOPPED') from exc
        state=self.inspect()
        require(state['tip']>=ordinal,'POST_COMMIT_VERIFICATION_FAILED')
        self.events.append({'ordinal':ordinal,'status':'COMMITTED_AND_VERIFIED'})
        return 'COMMITTED_AND_VERIFIED'

    def apply_remaining(self):
        state=self.inspect()
        for ordinal in range(state['tip']+1,8): self.apply_one(ordinal)
        final=self.inspect()
        require(final['tip']==7,'MIGRATION_BATCH_INCOMPLETE')
        return final
