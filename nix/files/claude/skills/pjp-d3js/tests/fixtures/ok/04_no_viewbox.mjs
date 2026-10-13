// viewBox を持たない SVG。白背景は width / height で敷く。
import * as d3 from "d3";

export default function () {
  const svg = d3.create("svg").attr("width", 300).attr("height", 150);
  svg.append("circle").attr("cx", 150).attr("cy", 75).attr("r", 40).attr("fill", "#eb6834");
  return svg.node();
}
