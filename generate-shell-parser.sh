#!/bin/bash
cd "$(dirname "$0")"
source ./script/setup.sh

if ! java -version &> /dev/null; then
    if test -f "./ShellParserGenerated/Sources/ShellParserGenerated/ShellLexer.swift" && \
       test -f "./ShellParserGenerated/Sources/ShellParserGenerated/ShellParser.swift"; then
        echo "Java is not available, but generated parser files exist. Skipping shell parser generation."
        exit 0
    fi
    echo "Java is required to generate shell parser. Please install Java or use the pre-generated files."
    exit 1
fi

./script/install-dep.sh --antlr
.deps/python-venv/bin/antlr4 -v "$antlr_version" -no-listener -Dlanguage=Swift \
    -o ./ShellParserGenerated/Sources/ShellParserGenerated \
    ./grammar/ShellLexer.g4 \
    ./grammar/ShellParser.g4


mv ./ShellParserGenerated/Sources/ShellParserGenerated/grammar/*.swift ./ShellParserGenerated/Sources/ShellParserGenerated/
rm -rf ./ShellParserGenerated/Sources/ShellParserGenerated/grammar # Antlr generates weird *.interp and *.tokens files

# Sources/ShellParserGenerated/ShellParser.swift:557:7: warning: variable '_prevctx' was written to, but never read
#                 var _prevctx: _localctx = _localctx
sed -i '' '/_prevctx/d' ./ShellParserGenerated/Sources/ShellParserGenerated/ShellParser.swift
