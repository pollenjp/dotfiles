// body に足してから返す書き方 (d3.select("body").append)。
import * as d3 from "d3";

export default function () {
  const svg = d3.select("body").append("svg").attr("id", "body-a").attr("width", 100).attr("height", 50);
  svg.append("rect").attr("width", 100).attr("height", 50).attr("fill", "#1baf7a");
  return svg.node();
}
