import base from "@devbie/style-guide/eslint/base";
import nest from "@devbie/style-guide/eslint/nest";

export default [
  ...base,
  ...nest,
  {
    ignores: ["dist/**", "coverage/**"],
  },
];
