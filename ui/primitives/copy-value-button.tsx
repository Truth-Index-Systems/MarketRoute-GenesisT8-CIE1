"use client";

import { useState } from "react";
import { Icon } from "@/ui/icons";

export function CopyValueButton({value,label="Copy"}:{value:string;label?:string}){
  const [copied,setCopied]=useState(false);
  async function copy(){
    try{
      await navigator.clipboard.writeText(value);
      setCopied(true);
      window.setTimeout(()=>setCopied(false),1400);
    }catch{
      setCopied(false);
    }
  }
  return <button type="button" className="mr-copy-action" onClick={copy} aria-label={`${label} ${value}`}><Icon name="copy" size={14}/>{copied?"Copied":label}</button>;
}
