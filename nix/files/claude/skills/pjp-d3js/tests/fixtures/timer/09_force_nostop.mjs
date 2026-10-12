// .stop() を忘れた力学グラフ。simulation は timer で動き続ける。
import * as d3 from "d3";

export default function () {
  const nodes = d3.range(5).map((i) => ({ id: i }));
  d3.forceSimulation(nodes).force("charge", d3.forceManyBody());
  return d3.create("svg").attr("width", 100).attr("height", 50).node();
}
