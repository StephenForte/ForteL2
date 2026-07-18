export const GUESTBOOK_ADDRESS = "0x9bAaB117304f7D6517048e371025dB8f89a8DbE5";
export const GUESTBOOK_ABI = [
  "function sign(string calldata text)",
  "function count() view returns (uint256)",
  "function getMessage(uint256 index) view returns (string)",
  "event MessageSigned(address indexed author, string text, uint256 index)",
];
