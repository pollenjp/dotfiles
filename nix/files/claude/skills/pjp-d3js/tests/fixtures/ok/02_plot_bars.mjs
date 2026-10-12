// Observable Plot の棒グラフ。document を渡さなくても動くかを見る。
import * as Plot from "@observablehq/plot";
import data from "./data/cities.json" with { type: "json" };

export default function () {
  return Plot.plot({
    width: 480,
    height: 240,
    y: { grid: true, label: "人口 (百万)" },
    marks: [Plot.barY(data, { x: "city", y: "value", fill: "#2a78d6" }), Plot.ruleY([0])],
  });
}
