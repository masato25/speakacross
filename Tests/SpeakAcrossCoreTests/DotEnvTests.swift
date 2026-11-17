import Testing
@testable import SpeakAcrossCore

@Test func dotEnvParsesCommonForms() {
    let values = DotEnv.parse("""
    # comment
    OPENAI_API_KEY=sk-test
    export MODEL="gpt-test"
    SINGLE='hello world'
    """)

    #expect(values["OPENAI_API_KEY"] == "sk-test")
    #expect(values["MODEL"] == "gpt-test")
    #expect(values["SINGLE"] == "hello world")
}

@Test func processEnvironmentWinsOverDotEnvLookup() {
    let value = DotEnv.value(
        for: "OPENAI_API_KEY",
        environment: ["OPENAI_API_KEY": "sk-shell"]
    )
    #expect(value == "sk-shell")
}
