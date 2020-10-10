const {time} = require("@openzeppelin/test-helpers");

async function latestTime() {
  return Number(await time.latest());
}

async function increaseTime(secondsPassed) {
  return time.increase(secondsPassed);
}

async function advanceBlock() {
  return time.advanceBlock();
}

module.exports = {
  latestTime,
  increaseTime,
  advanceBlock,
};
