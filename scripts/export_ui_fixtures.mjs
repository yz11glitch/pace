// Export UI-logic golden fixtures from public/ui-core.js for the native parity suite.
// Usage: node scripts/export_ui_fixtures.mjs [output_dir]
import {mkdirSync, writeFileSync} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {amountMinor, keypadAmount, manualCategoryChoices, money, noteFields, transactionCategory, validManualAmount} from "../public/ui-core.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = process.argv[2] ? resolve(process.argv[2]) : join(root, "fixtures", "golden");
mkdirSync(output, {recursive: true});

// Deterministic LCG so the fixture set is stable across runs.
let seed = 20260926;
const next = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
const pick = values => values[Math.floor(next() * values.length)];

const sorted = value => Array.isArray(value) ? value.map(sorted)
  : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])]))
  : value;
const write = (name, records) => {
  writeFileSync(join(output, name), records.map(record => JSON.stringify(sorted(record)) + "\n").join(""));
  console.log(`${name}: ${records.length} records`);
};

const keys = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "del"];
const sequences = [
  [], ["0"], ["0", "0"], ["0", "5"], ["."], [".", "5"], [".", ".", "5"], ["1", ".", "2", "3", "4"],
  ["1", "2", "3", "4", "5", "6", "7", "8"], ["1", "2", "3", "4", "5", "6", ".", "7", "8"],
  ["1", "8"], ["1", "8", "."], ["1", "8", ".", "0"], ["del"], ["1", "del", "del"],
  ["9", "9", "9", "9", "9", "9", "9", ".", "9", "9"], ["1", ".", "del", "5"], ["0", ".", "0", "1"],
];
for (let index = 0; index < 300; index++) {
  const length = Math.floor(next() * 14);
  sequences.push(Array.from({length}, () => pick(keys)));
}
write("keypad.jsonl", sequences.map((sequence, index) => {
  const value = sequence.reduce(keypadAmount, "");
  return {id: `keypad-${String(index).padStart(4, "0")}`, keys: sequence, value,
    amount_minor: amountMinor(value), valid: validManualAmount(value)};
}));

const amounts = [0, 1, 5, 9, 10, 99, 100, 101, 999, 1000, 1650, 12345, 99999, 100000, 123456,
  350000, 1000000, 12345678, 99999999, 100000000, 1234567890, 10000000000];
for (let index = 0; index < 60; index++) amounts.push(Math.floor(next() * 10 ** (1 + Math.floor(next() * 10))));
write("money.jsonl", amounts.map((minor, index) => ({id: `money-${String(index).padStart(3, "0")}`, minor, text: money(minor)})));

const notes = ["", "   ", "Chicken rice", "Dinner with friends.", "Is this right?", "Wow!", "Grab ride",
  "  Mamak  ", "x".repeat(60), "x".repeat(61), "Nasi lemak. ", "Teh tarik and roti canai at the mamak",
  "A".repeat(59) + ".", "Ends with ellipsis...", "Trailing space! ", "Café Déjà Vu"];
write("note_fields.jsonl", notes.map((note, index) => ({id: `note-${String(index).padStart(3, "0")}`, note, expect: noteFields(note)})));

const categoryCases = [];
for (const type of ["expense", "income", "refund", "contribution"]) {
  for (const selected of [undefined, "Other", "Income", "Food & Drink", "", null]) {
    for (const remembered of [undefined, "Other", "Income", "Transport", "", null]) {
      categoryCases.push({type, selected: selected ?? null, remembered: remembered ?? null,
        category: transactionCategory(type, selected, remembered), choices: manualCategoryChoices(type),
        defaults: {selected: selected === undefined, remembered: remembered === undefined}});
    }
  }
}
write("categories.jsonl", categoryCases.map((record, index) => ({id: `category-${String(index).padStart(3, "0")}`, ...record})));
