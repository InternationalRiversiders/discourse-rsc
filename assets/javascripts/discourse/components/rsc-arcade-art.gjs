import Component from "@glimmer/component";
import { eq } from "truth-helpers";
export default class extends Component {
 <template><svg class="ra-art" viewBox="0 0 240 160" aria-hidden="true">
 {{#if (eq @game '2048')}}
  <rect x="51" y="20" width="67" height="67" rx="13" fill="#fff7df"/><rect x="124" y="20" width="67" height="67" rx="13" fill="#f5c172"/><rect x="51" y="93" width="67" height="50" rx="13" fill="#f3d9ad"/><rect x="124" y="93" width="67" height="50" rx="13" fill="#fff7df"/>
  <g fill="#795936" font-family="system-ui" font-weight="800" text-anchor="middle"><text x="85" y="65" font-size="30">2</text><text x="157" y="65" font-size="30">8</text><text x="85" y="127" font-size="25">4</text><text x="157" y="127" font-size="25">2</text></g>
 {{else if (eq @game 'blocks')}}
  <g fill="#7464b8"><rect x="89" y="22" width="35" height="35" rx="6"/><rect x="89" y="63" width="35" height="35" rx="6"/><rect x="89" y="104" width="35" height="35" rx="6"/><rect x="48" y="104" width="35" height="35" rx="6"/></g><g fill="#a397d6"><rect x="130" y="63" width="35" height="35" rx="6"/><rect x="171" y="63" width="35" height="35" rx="6"/><rect x="130" y="104" width="35" height="35" rx="6"/><rect x="171" y="104" width="35" height="35" rx="6"/></g>
 {{else if (eq @game 'snake')}}
  <path d="M60 116H101V77H146V40H177" fill="none" stroke="#3b9675" stroke-width="25" stroke-linecap="round" stroke-linejoin="round"/><circle cx="183" cy="36" r="3" fill="white"/><circle cx="183" cy="46" r="3" fill="white"/><circle cx="62" cy="40" r="13" fill="#ed9383"/><path d="M62 28Q69 17 77 21" fill="none" stroke="#5c9671" stroke-width="5" stroke-linecap="round"/>
 {{else if (eq @game 'bird')}}
  <rect x="176" y="0" width="28" height="47" rx="6" fill="#7eb8a1"/><rect x="176" y="112" width="28" height="48" rx="6" fill="#7eb8a1"/><ellipse cx="103" cy="78" rx="39" ry="30" fill="#f5c76f"/><path d="M83 71Q44 54 68 100Q91 108 100 89" fill="#e6a465"/><circle cx="122" cy="68" r="11" fill="#fff8e6"/><circle cx="126" cy="68" r="4" fill="#384e5e"/><path d="M139 77L158 85L139 91" fill="#de8767"/>
 {{else if (eq @game 'hex')}}
  <g transform="translate(120 80)" stroke-width="17" fill="none" stroke-linejoin="round"><path d="M27 -47L54 0L27 47L-27 47L-54 0L-27 -47Z" stroke="#bb6c90"/><path d="M39 -67L78 0L39 67" stroke="#e19bad"/><path d="M-39 67L-78 0L-39 -67" stroke="#9482be"/></g><path d="M120 49L147 65V95L120 111L93 95V65Z" fill="#fff4f5"/>
 {{else if (eq @game 'bricks')}}
  <g fill="#c58966"><rect x="40" y="20" width="47" height="22" rx="5"/><rect x="96" y="20" width="47" height="22" rx="5"/><rect x="152" y="20" width="47" height="22" rx="5"/></g><g fill="#e4ae79"><rect x="40" y="51" width="47" height="22" rx="5"/><rect x="96" y="51" width="47" height="22" rx="5"/></g><path d="M163 76L132 109" fill="none" stroke="#fff7e8" stroke-width="4" stroke-linecap="round"/><circle cx="126" cy="116" r="8" fill="#9d7259"/><rect x="78" y="137" width="85" height="9" rx="4" fill="#9d7259"/>
 {{else}}
  <image href="/plugins/discourse-rsc/arcade/merge/09-bb68a2bb9cd6.png" x="58" y="6" width="137" height="137"/><image href="/plugins/discourse-rsc/arcade/merge/01-22a658c02581.png" x="20" y="99" width="49" height="49"/><image href="/plugins/discourse-rsc/arcade/merge/06-906829a14b81.png" x="182" y="100" width="45" height="45"/>
 {{/if}}</svg></template>
}
