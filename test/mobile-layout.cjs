const assert = require("node:assert/strict");

// Run against the isolated forum after browser.cjs has opened a real position.
// Click viewport coordinates so Playwright cannot hide a broken sticky tab by
// automatically scrolling it into view before the click.
module.exports = async function checkMobileLayout(page, output) {
  const navigations = [];
  const trackNavigation = (request) => {
    if (request.isNavigationRequest() && request.frame() === page.mainFrame()) {
      navigations.push(request.url());
    }
  };
  page.on("request", trackNavigation);
  try {
    for (const width of [320, 375, 390, 430, 480, 600, 700, 768, 1440]) {
      await page.setViewportSize({ width, height: 844 });
      await page.locator(".rsc-position").first().scrollIntoViewIfNeeded();
      const layout = await page.evaluate(() => {
        const position = document.querySelector(".rsc-position");
        return {
          overflow: document.documentElement.scrollWidth > innerWidth + 1,
          overview: position.querySelector(".rsc-position-overview").clientWidth,
          metrics: [...position.querySelectorAll(".rsc-position-overview dd")].map((el) => ({
            width: el.clientWidth,
            height: el.clientHeight,
          })),
        };
      });
      assert.equal(layout.overflow, false, `Page overflow at ${width}px`);
      assert(layout.overview >= 220, `Squeezed position at ${width}px`);
      assert(
        layout.metrics.every((m) => m.width >= 90 && m.height < 85),
        `Unreadable position metrics at ${width}px: ${JSON.stringify(layout)}`
      );

      if (width <= 700) {
        const visibleLinks = await page.locator(".rsc-tabs a").evaluateAll((links) =>
          links.every((el) => {
            const r = el.getBoundingClientRect();
            const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
            const header = document.querySelector(".d-header").getBoundingClientRect();
            return r.left >= 0 && r.right <= innerWidth + 1 && r.height >= 44 &&
              r.top >= header.bottom - 1 && el.contains(hit);
          })
        );
        assert(visibleLinks, `Navigation clipped or covered at ${width}px`);
        for (const path of ["sports", "market"]) {
          await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
          const link = page.locator(`.rsc-tabs a[href="/rsc/${path}"]`);
          const box = await link.boundingBox();
          assert(box && box.y >= 0 && box.y + box.height <= 844);
          await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
          await page.waitForURL(`**/rsc/${path}`);
          await page.locator(`.rsc-app[data-section="${path}"]`).waitFor();
        }
      }
    }
    assert.deepEqual(navigations, [], "Switching tabs must not reload the document");
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator(".rsc-position").first().scrollIntoViewIfNeeded();
    await page.screenshot({ path: `${output}/positions-mobile.png` });
    console.log("Position layout and scrolled navigation passed at nine viewport widths");
  } finally {
    page.off("request", trackNavigation);
  }
};
