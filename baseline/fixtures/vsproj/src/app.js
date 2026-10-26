// Entry point.
const { OLD_NAME } = require("./util");

function main() {
  console.log("Running", OLD_NAME.label);
  return OLD_NAME.run();
}

module.exports = { main, OLD_NAME };
