// 前の図 (06) が body に足した要素が残っていないこと (ファイルごとに document を作り直す)。
import * as d3 from "d3";

export default function ({ document }) {
  if (document.body.children.length !== 0) {
    throw new Error(`body に前の図の要素が残っている: ${document.body.innerHTML.slice(0, 80)}`);
  }
  if (document !== globalThis.document) throw new Error("引数の document と global の document が違う");
  return d3.create("svg").attr("width", 100).attr("height", 50).node();
}
