export const GUESTBOOK_ADDRESS = "0x0116686E2291dbd5e317F47faDBFb43B599786Ef";
export const GUESTBOOK_ABI = [
  "function sign(string calldata text)",
  "function count() view returns (uint256)",
  "function getMessage(uint256 index) view returns (string)",
  "event MessageSigned(address indexed author, string text, uint256 index)",
];
