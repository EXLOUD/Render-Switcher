import { defineConfig, globalIgnores } from "eslint/config";
import js from "@eslint/js";
import globals from "globals";

export default defineConfig([
	globalIgnores(["node_modules/"]),
	{
		files: ["**/*.js"],
		plugins: {
			js,
		},
		extends: ["js/recommended"],
		languageOptions: {
			ecmaVersion: "latest",
			sourceType: "module",
			globals: {
				...globals.browser,
			},
		},
		rules: {
			"no-unused-vars": "warn",
			"no-undef": "warn",
		},
	},
]);
