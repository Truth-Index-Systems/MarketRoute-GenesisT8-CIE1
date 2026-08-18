import { productEconomicsRepositoryFromEnvironment } from "../../platform/database/product-economics-repository";
export function productEconomicsSnapshot(at?:string){return productEconomicsRepositoryFromEnvironment().snapshot(at??new Date().toISOString());}
