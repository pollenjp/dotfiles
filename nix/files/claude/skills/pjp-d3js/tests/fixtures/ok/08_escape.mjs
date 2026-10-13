// 属性値と文字に & < > を含む。clipPath・linearGradient のように大文字を含む要素名と、
// xlink:href も入れる (書き出した SVG が XML として読めるかを見る)。
import * as d3 from "d3";

export default function () {
  const svg = d3.create("svg").attr("width", 240).attr("height", 80).attr("viewBox", [0, 0, 240, 80]);
  const defs = svg.append("defs");
  defs.append("clipPath").attr("id", "clip").append("rect").attr("width", 240).attr("height", 80);
  defs.append("linearGradient").attr("id", "grad").append("stop").attr("offset", "0").attr("stop-color", "#2a78d6");
  defs.append("circle").attr("id", "dot").attr("r", 4);
  svg
    .append("text")
    .attr("x", 10)
    .attr("y", 40)
    .attr("clip-path", "url(#clip)")
    .attr("aria-label", "R&D <推移>")
    .text("A & B <C>");
  svg.append("a").attr("href", "https://example.com/?a=1&b=2").append("circle").attr("cx", 200).attr("cy", 40).attr("r", 10);
  // d3 の .attr("xlink:href") は接頭辞の無い href で書かれるので、xlink:href をそのまま付ける
  svg.append("use").attr("x", 220).attr("y", 40).node().setAttribute("xlink:href", "#dot");
  return svg.node();
}
