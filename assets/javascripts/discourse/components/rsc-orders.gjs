import { formatDateTime, formatDate, formatTime } from "../lib/campus-time";
import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq, not } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { formatAmount, formatPrice, formatQuantity, signedAmount, valueTone } from "../lib/rsc-format";
const uiText = (key) => i18n(`discourse_rsc.ui.${key}`);
const dateLabel = (value) => formatDate(value);
const timeLabel = (value) => formatTime(value);
const when = formatDateTime;
export default class RscOrders extends Component {
  <template>
    <section id="rsc-orders" class="rsc-card">
      <h2>{{uiText "orders"}}</h2>
      <div class="rsc-scroll"><table class="rsc-compact-table rsc-orders-table">
        <thead><tr><th>时间</th><th>品种 / 方向</th><th class="rsc-number">数量</th><th class="rsc-number">成交价</th><th class="rsc-number">手续费</th><th class="rsc-number" title="平仓盈亏，手续费另列">盈亏（费前）</th><th>状态 / 详情</th></tr></thead>
        <tbody>{{#each @orders as |order|}}
          <tr id="rsc-order-{{order.id}}">
            <td><time datetime={{order.created_at}}>{{dateLabel order.created_at}}<small>{{timeLabel order.created_at}}</small></time></td>
            <td><strong>{{order.symbol}}</strong><small>{{uiText order.side}}{{#unless (eq order.side "close")}} · {{order.leverage}}×{{/unless}}</small></td>
            <td class="rsc-number">{{formatQuantity order.quantity}}</td>
            <td class="rsc-number">{{formatPrice order.details.price}}</td>
            <td class="rsc-number">{{formatAmount order.details.fee}}</td>
            <td class="rsc-number rsc-order-pnl">
              {{#if (eq order.side "close")}}{{#if (eq order.status "filled")}}<strong class={{valueTone order.details.pnl}} title={{order.details.pnl}}>{{signedAmount order.details.pnl}}</strong>{{else}}—{{/if}}{{else}}—{{/if}}
            </td>
            <td class="rsc-order-status"><span>{{uiText order.status}}</span>
              <details><summary>详情</summary><div class="rsc-order-details">
                {{#if order.details.reason}}{{#unless (eq order.details.reason "legacy_import")}}<p>{{uiText order.details.reason}}</p>{{/unless}}{{/if}}
                {{#if order.details.gross}}<p>名义金额 {{formatAmount order.details.gross}} RSC</p>{{/if}}
                {{#if order.details.payout}}<p>返还 {{formatAmount order.details.payout}} RSC</p>{{/if}}
                {{#if order.details.error}}<p role="status">{{order.error_message}}</p>{{/if}}
                {{#if (eq order.status "pending")}}<p>预占 {{formatAmount order.reserved}} RSC</p><p>最早处理 {{when order.execute_at}}</p><p>{{#if order.cancel_at}}可撤单时间 {{when order.cancel_at}}{{else}}撤单截止 {{when order.cancel_until}}{{/if}}</p><p>到期 {{when order.expires_at}}</p>{{/if}}
                <p>金额单位 RSC；平仓盈亏未扣手续费。</p>
              </div></details>
              {{#if (eq order.status "pending")}}<button class="btn btn-small" type="button" disabled={{if @busy true (not order.can_cancel)}} {{on "click" (fn @cancel order)}}>{{uiText "cancel"}}</button>{{/if}}
            </td>
          </tr>
        {{else}}<tr><td colspan="7">{{uiText "empty"}}</td></tr>{{/each}}</tbody>
      </table></div>
    </section>
  </template>
}
