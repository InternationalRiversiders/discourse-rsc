export function savedMarketQuery() {
  try {
    const saved = JSON.parse(sessionStorage.getItem("rsc:market-filters:v2") || "{}");
    return { market_search: typeof saved.search === "string" ? saved.search : "",
      market_category: typeof saved.category === "string" ? saved.category : "",
      market_sort: saved.sort || "popular", market_page: Number.isInteger(saved.page) ? saved.page : 1 };
  } catch { return {}; }
}
