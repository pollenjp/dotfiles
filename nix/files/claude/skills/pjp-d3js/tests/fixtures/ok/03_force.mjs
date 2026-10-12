// 原点を中心にした viewBox の力学グラフ。白背景が viewBox の左上から敷かれるか、
// .stop() して tick を手で回すと毎回同じ形になるかを見る。
import * as d3 from "d3";

export default function () {
  const w = 400;
  const h = 240;
  const nodes = d3.range(12).map((i) => ({ id: i }));
  const links = d3.range(1, 12).map((i) => ({ source: Math.floor((i - 1) / 2), target: i }));
  const sim = d3
    .forceSimulation(nodes)
    .force(
      "link",
      d3
        .forceLink(links)
        .id((d) => d.id)
        .distance(30),
    )
    .force("charge", d3.forceManyBody().strength(-60))
    .force("x", d3.forceX())
    .force("y", d3.forceY())
    .stop();
  for (let i = 0; i < 300; ++i) sim.tick();

  const svg = d3
    .create("svg")
    .attr("width", w)
    .attr("height", h)
    .attr("viewBox", [-w / 2, -h / 2, w, h]);
  svg
    .append("g")
    .attr("stroke", "#999999")
    .selectAll("line")
    .data(links)
    .join("line")
    .attr("x1", (d) => d.source.x)
    .attr("y1", (d) => d.source.y)
    .attr("x2", (d) => d.target.x)
    .attr("y2", (d) => d.target.y);
  svg
    .append("g")
    .attr("fill", "#2a78d6")
    .selectAll("circle")
    .data(nodes)
    .join("circle")
    .attr("cx", (d) => d.x)
    .attr("cy", (d) => d.y)
    .attr("r", 5);
  return svg.node();
}
