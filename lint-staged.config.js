import path from "path";

export default {
  "*": (absolutePaths) => {
    const cwd = process.cwd();
    const relativePaths = absolutePaths.map((file) => path.relative(cwd, file));

    return `trufflehog filesystem ${relativePaths.join(" ")} --fail --results=verified,unknown `;
  },
  "*.{rb,rake}": "bundle exec standardrb --fix",
  "*.html.erb": ["bundle exec herb analyze ./app", "erb_lint -a"],
  "*.{js,json}":
    "yarn run lint-javascript --fix --ignore-pattern app/assets/builds",
  "{app/assets/stylesheets/**/,app/components/**/}*.scss":
    "yarn run lint-scss --fix",
  "config/locales/**/*.yml": "bundle exec rake lint:translations",
};
