// 止まらない timer を残す (d3.interval を止めていない)。
import * as d3 from "d3";

export default function () {
  d3.interval(() => {}, 1000);
  return d3.create("svg").attr("width", 100).attr("height", 50).node();
}
