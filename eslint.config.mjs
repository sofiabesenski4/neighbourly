import globals from "globals";
import prettier from "eslint-plugin-prettier";
import prettierRecommended from "eslint-plugin-prettier/recommended";
import jsonc from "eslint-plugin-jsonc";

export default [
  {
    ignores: ["node_modules/**", "app/assets/builds/**", "lib/samples/**"],
  },
  {
    files: ["**/*.js", "**/*.json"],
    languageOptions: {
      globals: {
        ...globals.browser,
        $: "readonly",
        Spree: "readonly",
        Turbo: "readonly",
      },
    },
    settings: {
      "import/resolver": {
        webpack: {
          config: {
            resolve: {
              modules: ["node_modules"],
            },
          },
        },
      },
    },
    plugins: {
      prettier: prettier,
    },
    rules: {
      "no-console": "error",
      "class-methods-use-this": 0,
      "no-empty": ["error", { allowEmptyCatch: true }],
      "no-param-reassign": 0,
      "vars-on-top": 0,
      "prettier/prettier": "error",
    },
  },
  prettierRecommended,
  ...jsonc.configs["flat/recommended-with-jsonc"],
];
