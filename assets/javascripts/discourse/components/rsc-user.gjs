import Component from "@glimmer/component";
import DUserLink from "discourse/ui-kit/d-user-link";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";

// Only pass an identity authorized by the server. Anonymous content has no user.
export default class extends Component {
  <template>
    {{#if @user.username}}
      <DUserLink @user={{@user}} class="rsc-forum-user">
        {{#unless @hideAvatar}}{{dAvatar @user imageSize="small" loading="lazy"}}{{/unless}}
        <span>{{@user.username}}</span>
      </DUserLink>
    {{else}}
      <span class="rsc-user-label">{{@name}}</span>
    {{/if}}
  </template>
}
