function getEmittedEvent(eventName, receipt) {
  return receipt.events.find(({event}) => event === eventName);
}

module.exports = {
  getEmittedEvent,
};
