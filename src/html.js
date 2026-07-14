let hideTimeout = null;
function activate() {
  const tabbedContents = document.querySelectorAll(".tabbed-content");
  tabbedContents.forEach((tc) => {
    const tabs = tc.querySelectorAll(".tabs > li");
    const contentItems = tc.querySelectorAll(".content > div");
    tabs.forEach((tab, index) => {
      tab.addEventListener("click", () => {
        // Reset all tabs
        tabs.forEach((t) => {
          t.classList.remove("active");
          t.setAttribute("aria-selected", "false");
        });

        // Hide all content
        contentItems.forEach((item) => {
          item.classList.remove("show");
        });

        // Activate clicked tab
        tab.classList.add("active");
        tab.setAttribute("aria-selected", "true");

        // Show matching content
        contentItems[index].classList.add("show");
      });
    });

    const copy_svg = tc.querySelector(".tabs > .actions > .copy-svg");
    copy_svg.addEventListener("click", async function () {
      console.log(tc.querySelector(".diagram svg").outerHTML);
      await navigator.clipboard.write([
        new ClipboardItem({
          "text/plain": tc.querySelector(".diagram svg").outerHTML,
        }),
      ]);

      const tooltip = copy_svg.querySelector(".tooltip");
      tooltip.classList.add("visible");

      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }

      hideTimeout = setTimeout(() => {
        tooltip.classList.remove("visible");
        hideTimeout = null;
      }, 500);
    });

    const copy_ziggy = tc.querySelector(".tabs > .actions > .copy-ziggy");
    copy_ziggy.addEventListener("click", async function () {
      console.log(tc.querySelector("code").innerText);
      await navigator.clipboard.write([
        new ClipboardItem({
          "text/plain": tc.querySelector("code").innerText,
        }),
      ]);

      const tooltip = copy_ziggy.querySelector(".tooltip");
      tooltip.classList.add("visible");

      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }

      hideTimeout = setTimeout(() => {
        tooltip.classList.remove("visible");
        hideTimeout = null;
      }, 500);
    });

    const save_svg = tc.querySelector(".tabs > .actions > .save-svg");
    save_svg.addEventListener("click", async function () {
      const svg_src = tc.querySelector(".diagram svg").outerHTML;
      const idx = svg_src.indexOf("\n");

      const blob = new Blob(
        [
          svg_src.slice(0, idx + 1),
          document.getElementById("__railroad_css").outerHTML,
          svg_src.slice(idx),
        ],
        { type: "image/svg+xml" },
      );

      console.log(blob);

      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      link.download = tc.querySelector(".diagram-name").innerText + ".svg";
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(link.href);
    });
  });
}
