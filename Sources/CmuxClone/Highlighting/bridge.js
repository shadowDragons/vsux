/* vsux: native UTF-16 token bridge. Source strings are parser arguments, never scripts. */
hljs.registerLanguage('vue', function () {
    const grammar = hljs.getLanguage('xml').rawDefinition();
    grammar.name = 'Vue';
    grammar.aliases = [];
    for (const rule of grammar.contains) {
        if (!rule.starts) continue;
        if (String(rule.begin).includes('<script')) rule.starts.subLanguage = ['typescript', 'javascript'];
        if (String(rule.begin).includes('<style')) rule.starts.subLanguage = ['css', 'scss', 'less'];
    }
    return grammar;
});

function cmuxTokens(source, language, maximumLineLength) {
    if (!hljs.getLanguage(language)) return [];
    // Keep line breaks and exact UTF-16 length. Oversized lines remain plain;
    // ordinary lines still benefit from a grammar pass over the whole document.
    const skipped = [];
    const input = source.replace(/[^\r\n]+/g, function (line, offset) {
        if (line.length <= maximumLineLength) return line;
        skipped.push([offset, offset + line.length]);
        return ' '.repeat(line.length);
    });
    const tree = hljs.highlight(input, {language: language, ignoreIllegals: true})._emitter.rootNode;
    const result = [];
    let offset = 0, skipIndex = 0;
    function style(scope, inherited) {
        if (!scope) return inherited;
        if (scope.startsWith('language:') || scope === 'subst' || scope === 'params') return null;
        if (/^(comment|quote)(\.|$)/.test(scope)) return 'comment';
        if (scope === 'regexp') return 'regexp';
        if (/^(string|char|symbol|code)(\.|$)/.test(scope)) return 'string';
        if (/^(keyword|literal)(\.|$)/.test(scope)) return 'keyword';
        if (scope === 'operator') return null;
        if (/^(number)(\.|$)/.test(scope)) return 'number';
        if (/^(type|built_in|title\.class)(\.|$)/.test(scope)) return 'type';
        if (/^(title\.function|title)(\.|$)/.test(scope)) return 'function';
        if (/^(attr|attribute|property)(\.|$)/.test(scope)) return 'property';
        if (scope === 'name' || scope === 'selector-tag') return 'tag';
        if (/^(section|strong|emphasis|bullet|selector-id|selector-class)(\.|$)/.test(scope)) return 'heading';
        if (/^(meta|doctag)(\.|$)/.test(scope)) return 'meta';
        if (scope === 'addition') return 'inserted';
        if (scope === 'deletion') return 'deleted';
        return inherited;
    }
    function emit(start, end, kind) {
        if (!kind || end <= start) return;
        const last = result[result.length - 1];
        if (last && last[0] + last[1] === start && last[2] === kind) last[1] += end - start;
        else result.push([start, end - start, kind]);
    }
    function walk(node, inherited) {
        if (typeof node === 'string') {
            const start = offset, end = offset += node.length;
            if (!inherited) return;
            const kind = inherited === 'keyword' && /^(if|else|elif|unless|then|for|while|until|do|switch|case|default|break|continue|return|throw|throws|try|catch|finally|guard|defer|yield|await|async|in|of|import|from|export)$/.test(node.trim()) ? 'control' : inherited;
            let cursor = start;
            while (skipIndex < skipped.length && skipped[skipIndex][1] <= cursor) skipIndex++;
            for (let i = skipIndex; i < skipped.length && skipped[i][0] < end; i++) {
                emit(cursor, Math.min(end, skipped[i][0]), kind);
                cursor = Math.max(cursor, skipped[i][1]);
            }
            emit(cursor, end, kind);
            return;
        }
        const kind = style(node.scope, inherited);
        for (const child of node.children) walk(child, kind);
    }
    walk(tree, null);
    return offset === source.length ? result : [];
}
