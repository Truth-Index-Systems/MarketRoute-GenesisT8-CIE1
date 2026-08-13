# Commercial Reality application service

The Build 6 application service orchestrates already-declared subsystems only:

1. load the current campaign seller context,
2. evaluate `COMPANY_CORE_V1` Truth at one exact reference time,
3. evaluate Truth for any supported HARD seller-constraint claim keys,
4. fetch the database-normalised R4 context,
5. run the pure deterministic Commercial Reality kernel,
6. ask PostgreSQL to independently re-derive and persist the R4 decision.

It does not call AI and cannot write authority tables directly.
