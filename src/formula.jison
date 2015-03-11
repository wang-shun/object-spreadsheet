%lex

/* Don't allow leading - here; parse it as an operator instead. */
int ([0-9]|[1-9][0-9]+)
exp [eE][-+]?[0-9]+
frac "."[0-9]+

%%
\ + /* skip whitespace */
\n return 'NEWLINE'

/* Primitive literals */
{int}{frac}?{exp}?\b return 'NUMBER'
/* Hm, this does not match the unescaping code below. ~ Matt 2015-02-05 */
\"(?:'\\'[\\"bfnrt/]|'\\u'[a-fA-F0-9]{4}|[^\\\0-\x09\x0a-\x1f"])*\" yytext = yytext.substr(1,yyleng-2); return 'STRING'
"true" return 'TRUE'
"false" return 'FALSE'

/*
Set literals, operators, etc.

Careful: earlier entries take priority, so longer operators should go earlier.
*/
"(" return '('
")" return ')'
"[" return '['
"]" return ']'
"{" return '{'
"}" return '}'
"," return ','
":=" return ':='
"::" return 'ROOT'
":" return ':'
"|" return '|'
"=" return '='
"!=" return '!='
"<=" return '<='
"<" return '<'
">=" return '>='
">" return '>'
"+" return '+'
"-" return '-'
"*" return '*'
"/" return '/'
"^" return '^'
"." return '.'

"add" return 'ADD'
"all" return 'ALL'
"check" return 'CHECK'
"create" return 'CREATE'
"delete" return 'DELETE'
"else" return 'ELSE'
"foreach" return 'FOREACH'
"if" return 'IF'
"in" return 'IN'
"let" return 'LET'
"new" return 'NEW'
"remove" return 'REMOVE'
"set" return 'SET'
"to" return 'TO'

/* Identifiers */
/* XXX: Allow non-Latin word characters? */
[_A-Za-z][_A-Za-z0-9]* return 'IDENT'

<<EOF>> return 'EOF'

%%

// http://www.gnu.org/software/bison/manual/html_node/Multiple-start_002dsymbols.html
lexer.origLex = lexer.lex;
lexer.lex = function() {
  if (this.yy.startToken) {
    var token = this.yy.startToken;
    this.yy.startToken = null;
    // It's OK if this is a string; the parser is still capable of converting it
    // to a numeric token, even though the lexer normally returns numeric tokens
    // itself.
    return token;
  } else {
    return this.origLex();
  }
}

/lex

%start entryPointEOF

/*
Precedence level numbers are as used in stringify functions in
formulas.coffee.

Compare to:
http://www.gnu.org/software/bison/manual/html_node/Infix-Calc.html
*/
%nonassoc '=' '!=' '<' '<=' '>' '>=' IN  /* 1 */
%left '+' '-'     /* 2 */
%left '*' '/'     /* 3 */
%precedence NEG   /* 4 */
%right '^'        /* 5 */
%left '.'         /* 6 */

%%

/*
Surprisingly, "return" is the recommended way to get a result out of Jison:

http://librelist.com/browser//jison/2013/8/14/return-value-from-parse/#7dbd17a9671580afa948da054e97bfa6
*/
entryPointEOF
    : 'FORMULA' expression EOF
        { return $2; }
    | 'PROCEDURE' statements EOF
        { return $2; }
    ;

statements
    :
        { $$ = []; }
    | statements statement
        { $$ = $1.concat([$2]); }
    ;

/*
Putting the NLs here rather than in "statements" seems to be the easiest way to
avoid a shift-reduce conflict at the optElse in the IF production.  :/
*/
statement
    : LET IDENT '=' expression NL
        { $$ = ['let', $2, $4]; }
    | familyReference ':=' expression NL
        { $$ = ['set', $1, $3]; }
    | TO SET familyReference ADD expression NL
        { $$ = ['add', $3, $5]; }
    | FROM SET familyReference REMOVE expression NL
        { $$ = ['remove', $3, $5]; }
    | IF expression '{' NL statements '}' NL optElse
        { $$ = ['if', $2, $5, $7]; }
    | FOREACH expression '{' NL statements '}' NL
        { $$ = ['foreach', $2, $5]; }
    | DELETE expression NL
        { $$ = ['delete', $2]; }
    | optLet NEW familyReference NL  /* Rarely useful without a let... */
        { $$ = ['new', $1, $3]; }
    | optLet CREATE familyReference NL '[' expression ']'
        { $$ = ['create', $1, $3, $5]; }
    | CHECK expression ':' expression NL
        { $$ = ['check', $2, $4]; }
    ;

optLet
    :
        { $$ = null; }
    | LET IDENT '='
        { $$ = $2; }
    ;

optElse
    :
        { $$ = []; }
    | ELSE '{' NL statements '}' NL
        { $$ = $4; }
    ;

/*
The various "statement" productions that use this nonterminal require that it
be a real down-navigation (not to a key column).  The expression production also
allows up-navigations and variable references.
*/
familyReference
    : navigationStep  /* as expression, could be bound variable or implicit this */
        { $$ = [null, $1]; }
    | ROOT navigationStep
        { $$ = [['lit', '_root', [[]]], $2]; }
    | expression '.' navigationStep
        { $$ = [$1, $3]; }
    ;

expression
    : '(' expression ')'
        { $$ = $2; }
    | '{' '}'
        { $$ = ['union', []]; }
    | '{' commaSeparatedExpressions optComma '}'
        { $$ = ['union', $2]; }
    | atomicLiteral
        { $$ = $1; }
    | familyReference
        { $$ = yy.navigate($1[0], $1[1]); }
/*
TODO: Implement for consistency with the create statement.
    | familyReference '[' expression ']'
*/
    | '-' expression %prec NEG
        { $$ = ['neg', $2]; }
    | expression '+' expression
        { $$ = ['+', $1, $3]; }
    | expression '-' expression
        { $$ = ['-', $1, $3]; }
    | expression '*' expression
        { $$ = ['*', $1, $3]; }
    | expression '/' expression
        { $$ = ['/', $1, $3]; }
    | expression '^' expression
        { $$ = ['^', $1, $3]; }
    | expression '=' expression
        { $$ = ['=', $1, $3]; }
    | expression '!=' expression
        { $$ = ['!=', $1, $3]; }
    | expression '<' expression
        { $$ = ['<', $1, $3]; }
    | expression '<=' expression
        { $$ = ['<=', $1, $3]; }
    | expression '>' expression
        { $$ = ['>', $1, $3]; }
    | expression '>=' expression
        { $$ = ['>=', $1, $3]; }
    | expression IN expression
        { $$ = ['in', $1, $3]; }
    | '{' filterBinding '|' expression '}'
        { yy.unbindVar($2.var);
          $$ = ['filter', $2.domain, [$2.var, $4]]; }
    | IF '(' expression ',' expression ',' expression ')'
        { $$ = ['if', $3, $5, $7]; }
    ;

navigationStep
    : IDENT
        { $$ = $1; }
    | '[' IDENT ']'
        /* This is easy enough to recognize; no need for a data structure. */
        { $$ = '[' + $2 + ']'; }
    ;

/* Could use a mid-rule action if supported.
   https://github.com/zaach/jison/issues/69 */
filterBinding
    : ALL IDENT IN expression
        { yy.bindVar($2, $4);
          $$ = {var: $2, domain: $4}; }
    ;

commaSeparatedExpressions
    : expression
        { $$ = [$1]; }
    | commaSeparatedExpressions ',' expression
        { $$ = $1.concat([$3]); }
    ;

optComma
    : ','
    |
    ;

atomicLiteral
    : STRING
        { // replace escaped characters with actual character
          $$ = ['lit','_string',[
                 yytext.replace(/\\(\\|")/g, "$"+"1")
                       .replace(/\\n/g,'\n')
                       .replace(/\\r/g,'\r')
                       .replace(/\\t/g,'\t')
                       .replace(/\\v/g,'\v')
                       .replace(/\\f/g,'\f')
                       .replace(/\\b/g,'\b')
               ]];
        }
    | NUMBER
        {$$ = ['lit','_number',[Number(yytext)]];}
    | TRUE
        {$$ = ['lit','_bool',[true]];}
    | FALSE
        {$$ = ['lit','_bool',[false]];}
    ;

%%

/*
Portions derived from JSON Lint (https://github.com/zaach/jsonlint) under the following license:

Copyright (C) 2012 Zachary Carter

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
