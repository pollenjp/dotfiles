// title を付けると Plot は SVG ではなく <figure> を返す。
import * as Plot from "@observablehq/plot";

export default function () {
  return Plot.plot({ title: "題", marks: [Plot.dot([{ x: 1, y: 1 }], { x: "x", y: "y" })] });
}
