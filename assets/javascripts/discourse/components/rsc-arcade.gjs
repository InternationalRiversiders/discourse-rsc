import Component from "@glimmer/component";
import { modifier } from "ember-modifier";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import ArcadeApp from "../lib/arcade-app";
import { arcadeRequest } from "../lib/arcade-transport";

// The forum and the App embed mount the very same UI, controls and lifecycle.
export default class extends Component {
 mount=modifier((element)=>{
  const app=new ArcadeApp(element,{
   catalog:null,catalogError:null,
   reloadCatalog:()=>this.args.reloadCatalog?.(),updateSeason:(current)=>this.args.updateSeason?.(current),
   request:(action,payload)=>{const req=arcadeRequest(action,payload);return ajax(req.path,{ignoreUnsent:false,timeout:15000,type:req.method,...(req.method==='POST'?{contentType:'application/json',data:JSON.stringify(req.body)}:{})});},
   errorText:(e)=>extractError(e,'网络连接中断，请重试或读取已保存进度。')
  });
  this.app=app;return()=>{app.destroy();if(this.app===app){this.app=null;}};
 });
 update=modifier(()=>{this.app?.update({catalog:this.args.catalog,catalogError:this.args.catalogError});});
 <template><section class="ra-app" aria-label="街机区" {{this.mount}} {{this.update @catalog @catalogError}}></section></template>
}
