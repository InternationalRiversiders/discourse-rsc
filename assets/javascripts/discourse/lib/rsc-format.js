// Display precision only. Keep unmodified decimal strings in models and requests.
// Do not pass financial values through Number/parseFloat, even for large balances.
export function formatAmount(value, digits = 4) {
  if (value === null || value === undefined || value === "") {
    return "—";
  }
  const text = String(value);
  const match = /^(-?)([0-9]+)(?:\.([0-9]+))?$/.exec(text);
  if (!match) {
    return "—";
  }
  const [, sign, integer, decimal = ""] = match;
  const whole = integer.replace(/^0+(?=\d)/, "");
  const fraction = decimal.slice(0, digits).replace(/0+$/, "");
  const zero = /^0+$/.test(whole) && !fraction;
  if (zero && /[1-9]/.test(decimal) && digits > 0) {
    return `${sign ? ">-" : "<"}0.${"0".repeat(digits - 1)}1`;
  }
  return `${zero ? "" : sign}${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}${fraction ? "." + fraction : ""}`;
}
export const formatWallet = (value) => formatAmount(value, 2);
export const formatQuantity = (value) => formatAmount(value, 8);
export const formatPercent = (value) =>
  value === null || value === undefined ? "—" : `${formatAmount(value, 2)}%`;
export function formatPrice(value) {
  const text = String(value ?? "").replace(/^-/, "");
  const [whole, fraction = ""] = text.split(".");
  const digits = /[1-9]/.test(whole)
    ? 4
    : /[1-9]/.test(fraction.slice(0, 2))
      ? 6
      : /[1-9]/.test(fraction.slice(0, 4))
        ? 8
        : 10;
  return formatAmount(value, digits);
}
export const valueTone = (value) =>
  !value || !/[1-9]/.test(String(value))
    ? "neutral"
    : String(value).startsWith("-")
      ? "negative"
      : "positive";

export function signedAmount(value) {
  const formatted = formatAmount(value);
  return valueTone(value) === "positive" && formatted !== "—" && !formatted.startsWith("<")
    ? `+${formatted}`
    : formatted;
}
