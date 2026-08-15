import type { CanonicalSellerGenome } from "../../core/seller-genome/index";

const INDUSTRY_ALIASES:Record<string,readonly string[]>={
  software:["software","saas","software_as_a_service"],
  "professional-services":["professional_services","consulting","consultancy"],
  marketing:["marketing","advertising","digital_marketing"],
  recruitment:["recruitment","staffing","human_resources","hr"],
  finance:["finance","financial_services","fintech"],
  healthcare:["healthcare","health_tech","healthtech"],
  retail:["retail","ecommerce","e_commerce"],
  manufacturing:["manufacturing","industrial_manufacturing"],
  logistics:["logistics","supply_chain","transport","transportation","freight","warehousing"],
  construction:["construction","proptech","property_technology"],
};

const COUNTRY_ALIASES:Record<string,string>={uk:"GB",gb:"GB",great_britain:"GB",united_kingdom:"GB",england:"GB",scotland:"GB",wales:"GB",northern_ireland:"GB",us:"US",usa:"US",united_states:"US",united_states_of_america:"US"};

function normalise(value:string){return value.normalize("NFKC").toLowerCase().replace(/&/g," and ").replace(/[^a-z0-9]+/g,"_").replace(/^_+|_+$/g,"");}
function containsTerm(haystack:string,needle:string){return (`_${haystack}_`).includes(`_${needle}_`);}
function boundedInt(name:string,fallback:number,min:number,max:number){const n=Number(process.env[name]??fallback);return Number.isFinite(n)?Math.max(min,Math.min(max,Math.floor(n))):fallback;}

export function activationTargetCount(){return boundedInt("MARKETROUTE_BOOTSTRAP_TARGET_COUNT",12,5,25);}
export function activationMinimumBankTargets(desired=activationTargetCount()){return Math.min(desired,boundedInt("MARKETROUTE_BOOTSTRAP_MIN_BANK_TARGETS",5,1,25));}

export function activationIndustryKeys(genome:CanonicalSellerGenome,targetMarketText:string):string[]{
  const semantic=genome.semantic.targetCharacteristics.industryCodes.map(normalise);
  const declared=normalise(targetMarketText);
  const keys:string[]=[];
  for(const [key,aliases] of Object.entries(INDUSTRY_ALIASES))if(aliases.some(alias=>semantic.some(code=>containsTerm(code,alias))||containsTerm(declared,alias)))keys.push(key);
  return keys.sort();
}

export function activationCountryCodes(genome:CanonicalSellerGenome,targetMarketText:string):string[]{
  const values=new Set<string>();
  for(const constraint of genome.semantic.constraints.items){
    if(constraint.mode!=="HARD"||!["country","country_code","geography"].includes(constraint.constraintType))continue;
    for(const value of constraint.valueCodes)values.add(normalise(value));
  }
  const declared=normalise(targetMarketText);
  for(const alias of Object.keys(COUNTRY_ALIASES))if(containsTerm(declared,alias))values.add(alias);
  const codes=new Set<string>();
  for(const value of values){const aliased=COUNTRY_ALIASES[value];if(aliased)codes.add(aliased);else if(/^[a-z]{2}$/.test(value))codes.add(value.toUpperCase());}
  return [...codes].sort();
}
