export default function () {
  this.route("rsc", { path: "/rsc" }, function () {
    this.route("market");
    this.route("leaderboard");
    this.route("admin");
    this.route("sports");
    this.route("packet", { path: "/packets/:token" });
  });
}
