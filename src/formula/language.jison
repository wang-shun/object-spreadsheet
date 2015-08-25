%lex

/* Don't allow leading - here; parse it as an operator instead. */
int ([0-9]|[1-9][0-9]+)
exp [eE][-+]?[0-9]+
frac "."[0-9]+
ws [ \t\r]

%%
{ws}+ /* skip whitespace */
\n return 'NL'
\#[^\n]*\n return 'NL'  /* single-line comments */

/* Primitive literals */
{int}{frac}?{exp}?\b return 'NUMBER'
/* Hm, this does not match the unescaping code below. ~ Matt 2015-02-05 */
\"(?:'\\'[\\"bfnrt/]|'\\u'[a-fA-F0-9]{4}|[^\\\0-\x09\x0a-\x1f"])*\" yytext = yytext.substr(1,yyleng-2); return 'STRING'
d\"(?:'\\'[\\"bfnrt/]|'\\u'[a-fA-F0-9]{4}|[^\\\0-\x09\x0a-\x1f"])*\" yytext = yytext.substr(2,yyleng-3); return 'DATESTRING'
"true" return 'TRUE'
"false" return 'FALSE'

/*
Set literals, operators, etc.

Careful: earlier entries take priority, so longer operators should go earlier.
I've messed this up enough times that I'm prioritizing obvious correctness over
keeping similar operators together. ~ Matt 2015-03-11
*/
"&&" return '&&'
"||" return '||'
":=" return ':='
"!=" return '!='
"<=" return '<='
">=" return '>='
"$" return '$'
"(" return '('
")" return ')'
"[" return '['
"]" return ']'
"{" return '{'
"}" return '}'
"," return ','
":" return ':'
"|" return '|'
"!" return '!'
"=" return '='
"<" return '<'
">" return '>'
"+" return '+'
"-" return '-'
"*" return '*'
"/" return '/'
"^" return '^'
"." return '.'

"add" return 'ADD'
"check" return 'CHECK'
"count" return 'COUNT'
"delete" return 'DELETE'
"else" return 'ELSE'
"foreach" return 'FOREACH'
"if" return 'IF'
"in" return 'IN'
"let" return 'LET'
"make" return 'MAKE'
"new" return 'NEW'
"oneOf" return 'ONEOF'
"remove" return 'REMOVE'
"set" return 'SET'
"sum" return 'SUM'
"to" return 'TO'

/* Identifiers */
/* XXX: Allow non-Latin word characters? */
[_A-Za-z][_A-Za-z0-9]* return 'IDENT'
[`][^`]*[`] yytext = yytext.substr(1,yyleng-2); return 'IDENT'

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
Keep in sync with PRECEDENCE_* in formulas.coffee.

Compare to:
http://www.gnu.org/software/bison/manual/html_node/Infix-Calc.html

WARNING: Jison silently ignores %precedence declarations
(https://github.com/zaach/ebnf-parser/blob/5412bee3f848ce42b64eb11af6648450050bd7fd/bnf.l#L37)
and %prec declarations for unknown operators
(https://github.com/zaach/jison/blob/245f6dd9c0990c2dd05e9c44da0586b166d7f0d3/lib/jison.js#L326),
making the former easy to miss.  We have to use %nonassoc instead.
*/
%left '||'
%left '&&'
%nonassoc '=' '!=' '<' '<=' '>' '>=' IN
%left '+' '-'
%left '*' '/'
/* ! with unary - is taken from C; it's a little weird but I don't have any
   better idea. ~ Matt 2015-03-11 */
%nonassoc NEG '!'
%right '^'
%left '.'

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
    /* TODO: Allow shadowing only in if statements (the only compelling use case)? */
    : LET IDENT '=' expression NL
        { yy.bindVar($2, $4, true);
          $$ = ['let', $2, $4]; }
    | familyReference ':=' expression NL
        { $$ = ['set', yy.convertFamilyReference($1, false, false), $3]; }
    | TO SET familyReference ADD expression NL
        { $$ = ['add', yy.convertFamilyReference($3, false, false), $5]; }
    | FROM SET familyReference REMOVE expression NL
        { $$ = ['remove', yy.convertFamilyReference($3, false, false), $5]; }
    | ifHeader '{' NL statements '}' NL optElse
        { yy.commitVars();
          $$ = ['if', $1, $4, $7]; }
    | foreachHeader '{' NL statements '}' NL
        { yy.rollbackVars();
          $$ = ['foreach', $1.var, $1.domain, $4]; }
    | DELETE expression NL
        { $$ = ['delete', $2]; }
    | optLet NEW familyReference NL  /* Rarely useful without a let... */
        { if ($1) yy.bindVar($1, $3, true);
          $$ = ['new', $1, yy.convertFamilyReference($3, true, false)]; }
    | optLet MAKE familySliceReference NL
        { if ($1) yy.bindVar($1, $3, true);
          $$ = ['make', $1, yy.convertFamilyReference($3, true, true)]; }
    /* Future: Error messages. */
    | CHECK expression NL
        { $$ = ['check', $2]; }
    ;

ifHeader
    : IF '(' expression ')'
        { yy.pushVars();
          $$ = $3; }
    ;

optElse
    :
        { $$ = []; }
    | elseHeader '{' NL statements '}' NL
        { $$ = $4; }
    ;

elseHeader
    : ELSE
        { yy.nextBranch(); }
    ;

foreachHeader
    : FOREACH '(' IDENT IN expression ')'
        { yy.pushVars();
          yy.bindVar($3, $5, false);
          $$ = {var: $3, domain: $5}; }
    ;

optLet
    :
        { $$ = null; }
    | LET IDENT '='
        { $$ = $2; }
    ;

/*
The various "statement" productions that use this nonterminal require that it
be a real down-navigation (not to a key column).  The expression productions
also allow up-navigations and variable references.
*/
familyReferenceCommon
    : navigationStep  /* as expression, could be bound variable or implicit this */
        { $$ = [null, $1]; }
    | '$' navigationStep
        { $$ = [['lit', '_root', [[]]], $2]; }
    | expression '.' navigationStep
        { $$ = [$1, $3]; }
    ;

familyReference
    : familyReferenceCommon
        { $$ = yy.navigate($1[0], $1[1], null); }
    ;

familySliceReference
    : familyReferenceCommon '[' expression ']'
        { $$ = yy.navigate($1[0], $1[1], $3); }
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
        { $$ = $1; }
    | familySliceReference
        { $$ = $1; }
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
    | '{' binding '|' expression '}'
        { yy.unbindVar($2.var);
          $$ = ['filter', $2.domain, [$2.var, $4]]; }
    /* For demo purposes.  I'm not thrilled with this syntax.  Decoupling
       typechecking from parsing so that we have the option to put the binding
       after the expression (if we choose) is on the to-do list. :( ~ Matt */
    | 'SUM' '[' binding ']' '(' expression ')'
        { yy.unbindVar($3.var);
          $$ = ['sum', $3.domain, [$3.var, $6]]; }
    | COUNT '(' expression ')'
        { $$ = ['count', $3]; }
    | ONEOF '(' expression ')'
        { $$ = ['oneOf', $3]; }
    | IF '(' expression ',' expression ',' expression ')'
        { $$ = ['if', $3, $5, $7]; }
    | '!' expression
        { $$ = ['!', $2]; }
    | expression '&&' expression
        { $$ = ['&&', $1, $3]; }
    | expression '||' expression
        { $$ = ['||', $1, $3]; }
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
binding
    : IDENT ':' expression
        { yy.bindVar($1, $3, false);
          $$ = {var: $1, domain: $3}; }
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
          $$ = ['lit','text',[
                 yytext.replace(/\\(\\|")/g, "$"+"1")
                       .replace(/\\n/g,'\n')
                       .replace(/\\r/g,'\r')
                       .replace(/\\t/g,'\t')
                       .replace(/\\v/g,'\v')
                       .replace(/\\f/g,'\f')
                       .replace(/\\b/g,'\b')
               ]];
        }
    | DATESTRING
        {$$ = ['date',yytext];}
    | NUMBER
        {$$ = ['lit','number',[Number(yytext)]];}
    | TRUE
        {$$ = ['lit','bool',[true]];}
    | FALSE
        {$$ = ['lit','bool',[false]];}
    ;

%%

/*
Portions derived from JSON Lint (https://github.com/zaach/jsonlint) under the following license:

Copyright (C) 2012 Zachary Carter

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
