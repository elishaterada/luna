// Discuss: should the threshold include tax?
// A simple decision, made visible.

const order = {
  total: 120,
  member: true,
  destination: "Chicago"
};

function shippingFor(order) {
  if (order.member || order.total >= 100) {
    return "On us";
  }

  return "$8 flat rate";
}

// What if the customer is a member?
// What if the order is exactly $100?
