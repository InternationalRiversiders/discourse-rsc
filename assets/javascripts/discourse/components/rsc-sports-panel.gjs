import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { formatAmount } from "../lib/rsc-format";
const uiText = (value) => i18n(`discourse_rsc.ui.${value}`);
import RscTeam from "./rsc-team";
import { payout } from "../lib/rsc-estimate";
import { formatDateTime as when } from "../lib/campus-time";
export default class RscSportsPanel extends Component {
  @tracked league = "all";
  @tracked sport = "all";
  @tracked matchFilter = "open";
  @tracked predictionDrafts = {};
  stake = "10";
  constructor() {
    super(...arguments);
    if (this.args.focus?.match_id) { this.matchFilter = "all"; }
  }
  get data() { return this.args.data; }
  get busy() { return this.args.busy; }
  @action set(field, event) { this[field] = event.target.value; }
  get leagues() {
    return [...new Map(this.data.matches.map((match) => [match.league, { id: match.league, label: match.league_name || match.league }])).values()];
  }
  get matches() {
    return this.data.matches
      .filter((match) => (this.league === "all" || match.league === this.league) && (this.sport === "all" || match.sport === this.sport))
      .filter((match) => this.matchFilter === "all" || (this.matchFilter === "mine" && !!match.prediction) || (this.matchFilter === "open" && !match.locked_reason) || (this.matchFilter === "closed" && !!match.locked_reason && ["live","finished","canceled"].includes(match.status)) || (this.matchFilter === "unavailable" && !!match.locked_reason && ["scheduled","postponed"].includes(match.status)) || (this.matchFilter === "popular" && match.participants > 0))
      .sort((a,b) => this.matchFilter === "popular" ? b.participants-a.participants : 0)
      .map((match) => {
        const prediction = match.prediction;
        const draft = this.predictionDrafts[match.id] || {};
        const fresh =
          match.odds_at &&
          Date.now() - Date.parse(match.odds_at) <=
            this.data.odds_max_age_hours * 3600000;
        return {
          ...match,
          prediction,
          draftStake: draft.stake ?? prediction?.stake ?? this.stake,
          draftPick: draft.pick ?? prediction?.pick ?? "home",
          potentialPayout: payout(draft.stake ?? prediction?.stake ?? this.stake, match.odds[draft.pick ?? prediction?.pick ?? "home"]),
          locked:
            this.data.read_only || this.data.wallet.status !== "active" ||
            match.status !== "scheduled" ||
            Date.parse(match.starts_at) <= Date.now() ||
            !fresh,
          choices: ["home", ...(match.allow_draw ? ["draw"] : []), "away"]
            .filter((pick) => match.odds[pick])
            .map((pick) => ({
              pick,
              title: uiText(pick),
              odds: match.odds[pick],
            })),
        };
      });
  }
  @action draft(matchId, field, event) {
    this.predictionDrafts = {
      ...this.predictionDrafts,
      [matchId]: {
        ...this.predictionDrafts[matchId],
        [field]: event.target.value,
      },
    };
  }
  @action predict(match, event) {
    event.preventDefault();
    return this.args.send("predictions", {
      match_id: match.id,
      prediction_id: match.prediction?.id || "",
      pick: match.draftPick,
      stake: match.draftStake,
    });
  }
  @action cancelPrediction(match) {
    return this.args.send(`predictions/${match.prediction.id}/cancel`, {});
  }

  <template>
        <div class="rsc-filter-bar rsc-sports-filters"><label>项目<select {{on "change" (fn this.set "sport")}}><option value="all">全部项目</option><option value="soccer">足球</option><option value="basketball">篮球</option></select></label><label>赛事筛选<select {{on "change" (fn this.set "matchFilter")}}><option value="open">可预测</option><option value="popular">热门</option><option value="closed">已截止</option><option value="unavailable">未开放</option><option value="mine">我的预测</option><option value="all">全部</option></select></label>
        <label>{{uiText "league"}}<select
            {{on "change" (fn this.set "league")}}
          ><option value="all">{{uiText "category_all"}}</option>{{#each
              this.leagues
              as |league|
            }}<option
                value={{league.id}}
              >{{league.label}}</option>{{/each}}</select></label></div>
        <div class="rsc-grid">{{#each this.matches key="id" as |match|}}<article
              class="rsc-card rsc-match" id="rsc-match-{{match.id}}"
            ><div class="rsc-match-meta"><span
                  class="rsc-eyebrow"
                >{{match.league_name}}</span><span
                  class="rsc-state-pill"
                  data-status={{match.status}}
                >{{uiText match.status}}</span></div>
              {{#if match.stage}}<p class="rsc-muted">{{match.stage}}</p>{{/if}}
              <h2 class="rsc-teams"><RscTeam @name={{match.home_name}} @original={{match.home}} @logo={{match.home_logo}} /><span
                  class="rsc-versus"
                >VS</span><RscTeam @name={{match.away_name}} @original={{match.away}} @logo={{match.away_logo}} @away={{true}} /></h2>
              <p class="rsc-match-time">{{when match.starts_at}} · {{match.participants}} 人参与</p>
              {{#if match.venue}}<p class="rsc-muted">{{match.venue}}</p>{{/if}}
              {{#if match.status_detail}}<p class="rsc-muted">{{match.status_detail}}</p>{{/if}}
              <p>比分 {{match.score.home}} : {{match.score.away}}</p><p class="rsc-muted">赔率更新 {{when match.odds_at}}{{#if match.locked_reason}} · {{#if (eq match.locked_reason "odds_unavailable")}}赔率暂不可用{{else}}赛事已封盘{{/if}}{{/if}}</p><form
                {{on "submit" (fn this.predict match)}}
              ><div class="rsc-odds">{{#each match.choices as |choice|}}<label
                      class={{if
                        (eq choice.pick match.draftPick)
                        "selected"
                        ""
                      }}
                    ><input
                        type="radio"
                        name={{match.id}}
                        value={{choice.pick}}
                        checked={{eq choice.pick match.draftPick}}
                        disabled={{match.locked}}
                        {{on "change" (fn this.draft match.id "pick")}}
                      /><span>{{choice.title}}</span><strong
                      >{{choice.odds}}</strong></label>{{/each}}</div><label
                >{{uiText "stake"}}<input
                    required
                    inputmode="decimal"
                    value={{match.draftStake}}
                    disabled={{match.locked}}
                    {{on "input" (fn this.draft match.id "stake")}}
                  /></label><button
                  class="btn btn-primary"
                  type="submit"
                  disabled={{if this.busy true match.locked}}
                >{{#if match.locked}}{{uiText "locked"}}{{else if
                    (eq match.prediction.status "pending")
                  }}{{uiText "update_prediction"}}{{else}}{{uiText
                      "predict"
                    }}{{/if}}</button><p class="rsc-muted">预计返还 {{formatAmount match.potentialPayout}} RSC（含本金）</p></form>{{#if match.prediction}}<p
                  class="rsc-prediction"
                >{{uiText "your_prediction"}}:
                  {{uiText match.prediction.pick}}
                  ·
                  {{formatAmount match.prediction.stake}}
                  RSC @
                  {{match.prediction.odds}}
                  ·
                  {{uiText
                    match.prediction.status
                  }} · 预计返还 {{formatAmount match.prediction.potential_payout}} RSC · 实际返还 {{formatAmount match.prediction.payout}} RSC</p>{{#if match.prediction.can_cancel}}<button type="button" class="btn btn-flat" disabled={{this.busy}} {{on "click" (fn this.cancelPrediction match)}}>{{uiText "cancel_prediction"}}</button>{{/if}}{{/if}}</article>{{else}}<p class="rsc-empty">{{uiText
                "no_matches"
              }}</p>{{/each}}</div>
        <section class="rsc-card"><h2>{{uiText "predictions"}}</h2><div
            class="rsc-scroll"
          ><table><thead><tr><th>{{uiText "match"}}</th><th>{{uiText
                      "pick"
                    }}</th><th>{{uiText "stake"}}</th><th>{{uiText
                      "odds"
                    }}</th><th>{{uiText "status"}}</th><th>{{uiText
                      "payout"
                    }}</th></tr></thead><tbody>{{#each
                  this.data.predictions
                  as |prediction|
                }}<tr><td>{{prediction.match_name}}</td><td>{{uiText
                        prediction.pick
                      }}</td><td>{{formatAmount prediction.stake}}</td><td
                    >{{prediction.odds}}</td><td>{{uiText
                        prediction.status
                      }}</td><td>{{formatAmount
                        prediction.payout
                      }}</td></tr>{{else}}<tr><td colspan="6">{{uiText
                        "empty"
                      }}</td></tr>{{/each}}</tbody></table></div></section>
  </template>
}
