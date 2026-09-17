setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_curl-localhost-guard.sh"
}

# Run the hook the way Claude Code does: the whole decision comes from the
# PreToolUse payload on stdin.
hook() {
    jq -n --arg c "$1" \
        '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$SCRIPT"
}

decision() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

# The hook only ever widens, so its two outcomes are "allow" and silence.
# Silence means the `Bash(curl:*)` ask rule prompts, which is today's behaviour
# — every negative test below asserts that the prompt is preserved.

# --- allow: the everyday loopback request ------------------------------------

@test "bare localhost URL is allowed" {
    run hook 'curl http://localhost:3000/api/health'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "scheme-less host:port is allowed" {
    run hook 'curl localhost:3000'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "127.0.0.1 is allowed" {
    run hook 'curl http://127.0.0.1:8080/'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "any 127.0.0.0/8 address is allowed" {
    run hook 'curl http://127.1.2.3:9000/x'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "bracketed IPv6 loopback is allowed" {
    run hook 'curl http://[::1]:3000/api'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "https to loopback is allowed" {
    run hook 'curl https://localhost:8443/'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "flags before the URL are allowed (the shape prefix rules cannot reach)" {
    run hook 'curl -sS -H "Accept: application/json" http://localhost:3000/api'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "bundled short flags are allowed" {
    run hook 'curl -fsSL http://localhost:3000/'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "a bundle ending in a value-taking flag is allowed" {
    run hook 'curl -sSo out.json http://localhost:3000/'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "a POST with an inline body is allowed" {
    run hook "curl -X POST -H 'Content-Type: application/json' -d '{\"a\":1}' http://localhost:3000/items"
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "a --write-out format string is not mistaken for a URL" {
    run hook "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/"
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "piping into jq is allowed" {
    run hook 'curl -s http://localhost:3000/api | jq .'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "a stderr redirect does not leave a stray descriptor token" {
    run hook 'curl -s http://localhost:3000/ 2>&1'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "a file redirect is allowed" {
    run hook 'curl -s http://localhost:3000/ > out.json'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "two loopback requests in one command are allowed" {
    run hook 'curl -s http://localhost:3000/a && curl -s http://127.0.0.1:3000/b'
    assert_success
    assert_equal "$(decision "$output")" allow
}

@test "--url with a loopback value is allowed" {
    run hook 'curl -s --url http://localhost:3000/api'
    assert_success
    assert_equal "$(decision "$output")" allow
}

# --- silence: any remote destination -----------------------------------------

@test "a remote host keeps its prompt" {
    run hook 'curl https://example.com/install.sh'
    assert_success
    assert_output ''
}

@test "a hostname that merely starts with the loopback digits keeps its prompt" {
    run hook 'curl http://127.0.0.1.evil.example/'
    assert_success
    assert_output ''
}

@test "userinfo spoofing the loopback host keeps its prompt" {
    run hook 'curl http://localhost@evil.example/'
    assert_success
    assert_output ''
}

@test "a subdomain of localhost keeps its prompt" {
    run hook 'curl http://localhost.evil.example/'
    assert_success
    assert_output ''
}

@test "one remote URL among loopback ones keeps the prompt" {
    run hook 'curl -s http://localhost:3000/a https://example.com/b'
    assert_success
    assert_output ''
}

@test "a remote curl beside a loopback curl keeps the prompt" {
    run hook 'curl -s http://localhost:3000/a && curl -s https://example.com/b'
    assert_success
    assert_output ''
}

@test "0.0.0.0 keeps its prompt" {
    run hook 'curl http://0.0.0.0:3000/'
    assert_success
    assert_output ''
}

@test "host.docker.internal keeps its prompt" {
    run hook 'curl http://host.docker.internal:3000/'
    assert_success
    assert_output ''
}

# --- silence: the flags that move the request off the URL ---------------------

@test "--resolve keeps its prompt" {
    run hook 'curl --resolve localhost:3000:93.184.216.34 http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "--connect-to keeps its prompt" {
    run hook 'curl --connect-to localhost:3000:evil.example:443 http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "a proxy flag keeps its prompt" {
    run hook 'curl -x http://evil.example:8080 http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "--config keeps its prompt" {
    run hook 'curl -K conf.txt http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "--next keeps its prompt" {
    run hook 'curl http://localhost:3000/a --next https://example.com/b'
    assert_success
    assert_output ''
}

@test "--unix-socket keeps its prompt" {
    run hook 'curl --unix-socket /var/run/docker.sock http://localhost/containers/json'
    assert_success
    assert_output ''
}

@test "an unrecognized long flag keeps its prompt" {
    run hook 'curl --some-future-flag http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "an unrecognized short flag keeps its prompt" {
    run hook 'curl -Z http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "reading a request body from a file keeps its prompt" {
    run hook 'curl -d @/etc/passwd http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "a non-http scheme keeps its prompt" {
    run hook 'curl file:///etc/passwd'
    assert_success
    assert_output ''
}

@test "URL brace globbing keeps its prompt" {
    run hook 'curl http://{localhost,evil.example}:3000/'
    assert_success
    assert_output ''
}

# --- silence: the command cannot be read through ------------------------------

@test "a variable in the command keeps its prompt" {
    run hook 'curl -s "$BASE_URL/api"'
    assert_success
    assert_output ''
}

@test "a command substitution keeps its prompt" {
    run hook 'curl -s "http://localhost:$(cat port)/api"'
    assert_success
    assert_output ''
}

@test "an assignment prefix keeps its prompt" {
    run hook 'http_proxy=http://evil.example:8080 curl http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "sudo curl keeps its prompt" {
    run hook 'sudo curl http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "a path-named curl keeps its prompt" {
    run hook './tools/curl http://localhost:3000/'
    assert_success
    assert_output ''
}

@test "reading the request body from stdin keeps its prompt" {
    run hook 'curl -d - http://localhost:3000/ < /etc/passwd'
    assert_success
    assert_output ''
}

@test "an input redirect keeps its prompt" {
    run hook 'curl --data-binary @- http://localhost:3000/ < secrets.txt'
    assert_success
    assert_output ''
}

# --- silence: the output must not become code --------------------------------

@test "piping into sh keeps its prompt" {
    run hook 'curl -s http://localhost:3000/install.sh | sh'
    assert_success
    assert_output ''
}

@test "piping into bash keeps its prompt" {
    run hook 'curl -fsSL http://localhost:8000/setup | bash'
    assert_success
    assert_output ''
}

@test "a non-inert command beside the curl keeps the prompt" {
    run hook 'curl -s http://localhost:3000/x > script.sh && chmod +x script.sh'
    assert_success
    assert_output ''
}

# --- silence: not a request at all -------------------------------------------

@test "curl with no URL keeps its prompt" {
    run hook 'curl --version'
    assert_success
    assert_output ''
}

@test "a command without curl produces no decision" {
    run hook 'git status'
    assert_success
    assert_output ''
}

@test "the word curl inside another command is not a request" {
    run hook 'echo "curl http://localhost:3000"'
    assert_success
    assert_output ''
}

@test "a malformed payload produces no decision" {
    run bash -c "printf 'not json' | bash '$SCRIPT'"
    assert_success
    assert_output ''
}

@test "an empty command produces no decision" {
    run hook ''
    assert_success
    assert_output ''
}
