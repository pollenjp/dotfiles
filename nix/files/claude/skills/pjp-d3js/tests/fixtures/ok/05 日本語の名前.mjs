// ファイル名に空白と日本語を含む。出力は out/05 日本語の名前.svg。
import * as d3 from "d3";

export default function () {
  const svg = d3.create("svg").attr("width", 200).attr("height", 100).attr("viewBox", [0, 0, 200, 100]);
  svg
    .append("text")
    .attr("x", 20)
    .attr("y", 55)
    .attr("font-family", "sans-serif")
    .attr("font-size", 20)
    .text("日本語のラベル");
  return svg.node();
}
