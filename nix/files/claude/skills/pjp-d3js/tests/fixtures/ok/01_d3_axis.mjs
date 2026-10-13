// D3 の棒グラフ。部品 (_palette.mjs) と JSON の import が効くかを見る。
import * as d3 from "d3";
import { blue } from "./_palette.mjs";
import data from "./data/cities.json" with { type: "json" };

export default function () {
  const width = 640;
  const height = 320;
  const m = { top: 16, right: 16, bottom: 28, left: 40 };
  const x = d3
    .scaleBand(
      data.map((d) => d.city),
      [m.left, width - m.right],
    )
    .padding(0.2);
  const y = d3.scaleLinear([0, d3.max(data, (d) => d.value)], [height - m.bottom, m.top]).nice();

  const svg = d3.create("svg").attr("width", width).attr("height", height).attr("viewBox", [0, 0, width, height]);
  svg.append("g").attr("transform", `translate(0,${height - m.bottom})`).call(d3.axisBottom(x));
  svg.append("g").attr("transform", `translate(${m.left},0)`).call(d3.axisLeft(y));
  svg
    .append("g")
    .attr("fill", blue)
    .selectAll("rect")
    .data(data)
    .join("rect")
    .attr("x", (d) => x(d.city))
    .attr("y", (d) => y(d.value))
    .attr("width", x.bandwidth())
    .attr("height", (d) => y(0) - y(d.value));
  return svg.node();
}
