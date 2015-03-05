%lex

/* Don't allow leading - here; parse it as an operator instead. */
int ([0-9]|[1-9][0-9]+)
exp [eE][-+]?[0-9]+
frac "."[0-9]+

%%
\s+ /* skip whitespace */

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
"::" return 'ROOT'
"|" return '|'
"=" return '='
"!=" return '!='
"<=" return '<='
"<" return '<'
">=" return '>='
">" return '>'
"all" return 'ALL'
"if" return 'IF'
"in" return 'IN'
"+" return '+'
"-" return '-'
"*" return '*'
"/" return '/'
"^" return '^'
"." return '.'

/* Identifiers */
/* XXX: Allow non-Latin word characters? */
[_A-Za-z][_A-Za-z0-9]* return 'IDENT'

<<EOF>> return 'EOF'

%%

/lex

%start expressionEOF

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
Surprisingly, this is the recommended way to get a result out of Jison:

http://librelist.com/browser//jison/2013/8/14/return-value-from-parse/#7dbd17a9671580afa948da054e97bfa6
*/
expressionEOF
    : expression EOF
        { return $1; }
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
    | navigationStep  /* could be bound variable or implicit this */
        { $$ = yy.navigate(null, $1); }
    | ROOT navigationStep
        { $$ = yy.navigate(['lit', '_root', [[]]], $2); }
    | expression '.' navigationStep
        { $$ = yy.navigate($1, $3); }
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
    | 'IF' '(' expression ',' expression ',' expression ')'
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
binding
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
