import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_TOOLTIP_CLASSES } from "utils/chart_tooltip";

// Connects to data-controller="category-histogram"
// Renders a stacked bar chart: each month is one bar, and the selected
// categories are stacked on top of each other using their own color, so the
// user can see where their money goes month over month.
// Modeled after bar_chart_controller's lifecycle (install/teardown,
// ResizeObserver, turbo:load reinstall, page-relative tooltip positioning).
export default class extends Controller {
  static targets = ["chartContainer", "legend"];
  static values = {
    data: { type: Array, default: [] },
    currency: { type: String, default: "USD" },
    transactionsPath: { type: String, default: "" },
  };

  _resizeObserver = null;

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this.element);
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    if (this.hasChartContainerTarget) {
      d3.select(this.chartContainerTarget).selectAll("*").remove();
    }
    if (this.hasLegendTarget) {
      this.legendTarget.innerHTML = "";
    }
  }

  _install() {
    if (!this.hasChartContainerTarget) return;

    const width = this.chartContainerTarget.clientWidth;
    const height = this.chartContainerTarget.clientHeight;
    const data = this.dataValue || [];

    if (width < 50 || height < 50 || data.length === 0) return;

    // Collect the full set of categories across all months so the stack
    // order is stable and every segment has a slot even if a given month
    // has no value for it.
    const categoryKeys = new Set();
    data.forEach((month) => {
      (month.segments || []).forEach((seg) => categoryKeys.add(seg.name));
    });
    const categories = Array.from(categoryKeys);

    if (categories.length === 0) return;

    // Map each category name to its color (from the first segment found).
    const colorByName = {};
    data.forEach((month) => {
      (month.segments || []).forEach((seg) => {
        colorByName[seg.name] = seg.color;
      });
    });

    const margin = { top: 16, right: 16, bottom: 56, left: 64 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const svg = d3
      .select(this.chartContainerTarget)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height]);

    const group = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);

    // X scale: one band per month
    const xScale = d3
      .scaleBand()
      .domain(data.map((d) => d.month_label))
      .range([0, innerWidth])
      .padding(0.25);

    // Build a per-month lookup: { categoryName: value }
    const monthValues = data.map((d) => {
      const byName = {};
      (d.segments || []).forEach((seg) => { byName[seg.name] = seg.value; });
      return byName;
    });

    // Y scale: stacked total
    const maxValue = d3.max(monthValues, (d) =>
      d3.sum(categories, (c) => d[c] || 0)
    ) || 1;

    const yScale = d3
      .scaleLinear()
      .domain([0, maxValue * 1.1])
      .range([innerHeight, 0]);

    // Tooltip
    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0 pointer-events-none`);

    const showTooltip = (event, monthLabel, rows) => {
      // The tooltip is absolutely positioned inside `this.element` (which is
      // position:relative), so convert page-relative cursor coords to
      // container-relative coords before setting left/top.
      const rect = this.element.getBoundingClientRect();
      const relX = event.pageX - rect.left + window.scrollX;
      const relY = event.pageY - rect.top + window.scrollY;

      const estimatedWidth = 240;
      const pageWidth = document.body.clientWidth;
      const tooltipX = relX + 10;
      const overflowX = event.pageX + 10 + estimatedWidth - pageWidth;
      const adjustedX = overflowX > 0 ? relX - overflowX - 20 : tooltipX;

      const total = d3.sum(rows, (r) => r.value);
      const rowsHtml = rows
        .slice()
        .sort((a, b) => b.value - a.value)
        .map(
          (r) =>
            `<div class="flex items-center justify-between gap-3 tabular-nums">
               <span class="flex items-center gap-1.5 text-secondary">
                 <span class="inline-block w-2 h-2 rounded-full" style="background-color: ${r.color};"></span>
                 ${r.name}
               </span>
               <span class="text-primary font-medium">${this._formatCurrency(r.value)}</span>
             </div>`
        )
        .join("");

      tooltip
        .html(
          `<div class="text-xs text-secondary mb-2">${monthLabel}</div>
           <div class="space-y-1">${rowsHtml}</div>
           <div class="mt-2 pt-2 border-t border-tertiary flex items-center justify-between tabular-nums">
             <span class="text-secondary text-xs">${this._t("total")}</span>
             <span class="text-primary font-semibold">${this._formatCurrency(total)}</span>
           </div>`
        )
        .style("opacity", 1)
        .style("left", `${adjustedX}px`)
        .style("top", `${relY - 10}px`);
    };

    const hideTooltip = () => tooltip.style("opacity", 0);

    // Stack: d3.stack needs an array of objects keyed by category name
    const stack = d3
      .stack()
      .keys(categories)
      .value((d, key) => d[key] || 0)
      .order(d3.stackOrderAscending)
      .offset(d3.stackOffsetNone);

    const stacked = stack(monthValues);

    // Draw stacked segments. Each <g.layer> corresponds to one category,
    // and its children <rect>s map 1:1 to the months in `data`.
    const layers = group
      .selectAll("g.layer")
      .data(stacked)
      .join("g")
      .attr("class", "layer")
      .attr("fill", (layer) => colorByName[layer.key]);

    layers
      .selectAll("rect")
      .data((layer) => layer)
      .join("rect")
      .attr("x", (d, i) => xScale(data[i].month_label))
      .attr("y", (d) => yScale(d[1]))
      .attr("width", xScale.bandwidth())
      .attr("height", (d) => Math.max(0, yScale(d[0]) - yScale(d[1])))
      .attr("rx", 2)
      .attr("ry", 2)
      .style("cursor", "pointer")
      .on("mousemove", function (event, d) {
        const layerGroup = this.parentNode;
        const monthIndex = Array.from(layerGroup.children).indexOf(this);
        const monthLabel = data[monthIndex]?.month_label || "";
        const rows = (data[monthIndex]?.segments || []).map((seg) => ({
          name: seg.name,
          color: seg.color,
          value: seg.value,
        }));
        showTooltip(event, monthLabel, rows);
      })
      .on("mouseout", hideTooltip)
      .on("click", (event, d) => {
        // d is a stacked series element; the layer's key is the category name.
        // Find the month index from the bound data position.
        const layer = event.target.parentNode;
        const monthIndex = Array.from(layer.children).indexOf(event.target);
        const monthData = data[monthIndex];
        if (!monthData) return;
        const categoryName = d3.select(layer).datum().key;
        this._navigateToTransactions(categoryName, monthData.month);
      });

    // X axis
    group
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(d3.axisBottom(xScale).tickSize(0))
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", "text-secondary")
      .style("font-size", "12px")
      .style("font-weight", "500")
      .attr("transform", "rotate(-40) translate(-6,0)")
      .style("text-anchor", "end");

    // Y axis
    group
      .append("g")
      .call(
        d3
          .axisLeft(yScale)
          .tickSize(0)
          .ticks(5)
          .tickFormat((d) => this._formatCurrency(d))
      )
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", "text-secondary")
      .style("font-size", "12px")
      .style("font-weight", "500");

    // Legend
    if (this.hasLegendTarget && categories.length > 0) {
      const legend = d3.select(this.legendTarget);
      legend.selectAll("*").remove();

      const item = legend
        .selectAll(".legend-item")
        .data(categories)
        .join("div")
        .attr(
          "class",
          "flex items-center gap-1.5 text-xs text-secondary whitespace-nowrap cursor-pointer hover:text-primary"
        )
        .on("click", (event, categoryName) => {
          // Navigate to transactions for this category across the full period
          const firstMonth = data[0]?.month;
          const lastMonth = data[data.length - 1]?.month;
          if (firstMonth && lastMonth) {
            this._navigateToTransactions(categoryName, firstMonth, lastMonth);
          }
        });

      item
        .append("span")
        .attr("class", "inline-block w-2.5 h-2.5 rounded-full")
        .style("background-color", (c) => colorByName[c]);

      item.append("span").text((c) => c);
    }
  }

  _navigateToTransactions(categoryName, month, endMonth) {
    if (!this.transactionsPathValue) return;

    // `month` and `endMonth` are ISO date strings (YYYY-MM-DD) from the
    // serialized @monthly_data. Work with strings directly to avoid
    // timezone shifts from Date parsing.
    const startStr = month.slice(0, 10);
    let endStr;

    // Compute last day of the month in local time, formatted as YYYY-MM-DD.
    // Using toISOString() would convert back to UTC and shift the date
    // backwards in positive-UTC timezones (e.g. NZ Mar 31 -> Mar 30).
    const lastDayOfMonth = (dateStr) => {
      const [y, m] = dateStr.split("-").map(Number);
      return new Date(y, m, 0).getDate(); // day 0 of next month = last day
    };

    const formatDate = (y, m, d) =>
      `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;

    if (endMonth) {
      const [y, m] = endMonth.slice(0, 10).split("-").map(Number);
      endStr = formatDate(y, m, lastDayOfMonth(endMonth.slice(0, 10)));
    } else {
      const [y, m] = startStr.split("-").map(Number);
      endStr = formatDate(y, m, lastDayOfMonth(startStr));
    }

    const url = this.transactionsPathValue
      .replace("__START_DATE__", startStr)
      .replace("__END_DATE__", endStr);

    // Append category filter
    const separator = url.includes("?") ? "&" : "?";
    window.location.href = `${url}${separator}q[categories][]=${encodeURIComponent(categoryName)}`;
  }

  _formatCurrency(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
        maximumFractionDigits: 0,
        minimumFractionDigits: 0,
      }).format(value);
    } catch {
      return value;
    }
  }

  _t(key) {
    const translations = { total: "Total" };
    return translations[key] || key;
  }
}
