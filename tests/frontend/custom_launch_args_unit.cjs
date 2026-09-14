const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..", "..");
const source = fs.readFileSync(path.join(ROOT, "ui", "js", "flag-core.js"), "utf8");
const context = {
    window: {},
};

vm.createContext(context);
vm.runInContext(source, context, { filename: "flag-core.js" });

const parse = context.window.LlamaGui.flagCore.parseCustomLaunchArgs;

function assertTokens(raw, expected) {
    const result = parse(raw);
    assert.equal(result.error, undefined);
    assert.deepEqual(Array.from(result.tokens), expected);
}

assertTokens("--threads 8 --flash-attn --parallel 4", ["--threads", "8", "--flash-attn", "--parallel", "4"]);
assertTokens("--threads 8\n--flash-attn\n--parallel 4", ["--threads", "8", "--flash-attn", "--parallel", "4"]);
assertTokens("--chat-template-kwargs '{\"preserve_thinking\":true}'", ["--chat-template-kwargs", "{\"preserve_thinking\":true}"]);
assertTokens('--log-prefix "my local test"', ["--log-prefix", "my local test"]);
assertTokens('--label "say \\"hello\\""', ["--label", 'say "hello"']);
assertTokens(String.raw`--label "say \"hello\" and \\bye"`, ["--label", String.raw`say "hello" and \bye`]);
assertTokens('--empty ""', ["--empty", ""]);
assertTokens(String.raw`--log-file C:\temp\llama.log`, ["--log-file", String.raw`C:\temp\llama.log`]);
assertTokens(String.raw`--log-file "C:\Users\pegas\My Models\model.gguf"`, ["--log-file", String.raw`C:\Users\pegas\My Models\model.gguf`]);
assertTokens(String.raw`--log-prefix my\ local\ test`, ["--log-prefix", "my local test"]);
assertTokens(String.raw`--label say\"hello\"`, ["--label", 'say"hello"']);
assertTokens("--path C:\\temp\\", ["--path", "C:\\temp\\"]);

const state = context.window.LlamaGui.flagCore;
state.replaceFlagValues({ tools: ["web_search"], temperature: 0.7 });
const snapshot = state.getFlagValues();
snapshot.tools.push("mutated");
snapshot.temperature = 1.5;
assert.equal(
    JSON.stringify(state.getFlagValues()),
    JSON.stringify({ tools: ["web_search"], temperature: 0.7 })
);

assert.match(parse("--flag 'unterminated").error, /unmatched single quote/);
assert.match(parse('--flag "unterminated').error, /unmatched double quote/);
assert.match(parse('--flag "unterminated\\').error, /unfinished escape/);

console.log("custom launch args parser tests passed");

const parseEnv = state.parseEnvironmentVariables;
const envText = "LLAMA_MMAP_RANDOM=1\r\nGGML_OP_OFFLOAD_MIN_BATCH=512";
assert.deepEqual(JSON.parse(JSON.stringify(parseEnv(envText).env)), {
    LLAMA_MMAP_RANDOM: "1", GGML_OP_OFFLOAD_MIN_BATCH: "512",
});
assert.equal(parseEnv("\nGGML_TEST=literal=a; $HOME 'quoted'\n").env.GGML_TEST, "literal=a; $HOME 'quoted'");
assert.equal(parseEnv("GGML_TEST=").env.GGML_TEST, "");
for (const raw of ["GGML_TEST", "PATH=x", "LLAMA_GUI_PORT=4", "LLAMA_ARG_API_KEY=secret", "GGML_X=1\nGGML_X=2", "GGML_X=a\0b", "x".repeat(16001), {}]) {
    assert.ok(parseEnv(raw).error, `must reject ${JSON.stringify(raw)}`);
}
state.applyFlagValues({ custom_env: envText });
assert.equal(state.getFlagValues().custom_env, envText);
assert.equal(state.getLaunchArgs().env.GGML_OP_OFFLOAD_MIN_BATCH, "512");
assert.ok(!state.getLaunchArgs().args.flat().includes("GGML_OP_OFFLOAD_MIN_BATCH=512"));
state.setFlagValue("custom_env", "INVALID=1");
assert.match(state.getLaunchArgs().error, /Environment Variables/);
state.applyFlagValues({});
assert.deepEqual(Object.keys(state.getLaunchArgs().env), []);
console.log("environment variables parser and shared state tests passed");
