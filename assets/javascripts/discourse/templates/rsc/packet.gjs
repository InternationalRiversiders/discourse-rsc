import RscDashboard from "../../components/rsc-dashboard";
import RscPacketPreview from "../../components/rsc-packet-preview";
export default <template>
  {{#if @controller.model.preview}}
    <RscPacketPreview @model={{@controller.model}} />
  {{else}}
  <RscDashboard @model={{@controller.model}} @section="packet" />
  {{/if}}
</template>
