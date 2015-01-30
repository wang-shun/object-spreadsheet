/*
Interactive testing:

$ meteor shell
> JSON.stringify(Jison.Parsers.formula.parse('{m in ::Meeting | m.slot = Slot}'))
*/

%lex

int "-"?([0-9]|[1-9][0-9]+)
exp [eE][-+]?[0-9]+
frac "."[0-9]+

%%
\s+ /* skip whitespace */

/* Primitive literals */
{int}{frac}?{exp}?\b return 'NUMBER'
\"(?:'\\'[\\"bfnrt/]|'\\u'[a-fA-F0-9]{4}|[^\\\0-\x09\x0a-\x1f"])*\" yytext = yytext.substr(1,yyleng-2); return 'STRING'
"true" return 'TRUE'
"false" return 'FALSE'

/* Set literals, operators, etc. */
"(" return '('
")" return ')'
"{" return '{'
"}" return '}'
"," return ','
"|" return '|'
"=" return '='
"in" return 'IN'
"::" return 'ROOT'
"." return '.'

/* Identifiers */
/* XXX: Allow non-Latin word characters? */ 
[_A-Za-z][_A-Za-z0-9]* return 'IDENT'

<<EOF>> return 'EOF'

%%

/lex

%start expressionEOF

%nonassoc '=' IN
%left '.'

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
    | singletonLiteral
        { $$ = $1; }
    | setLiteral
        { $$ = $1; }
    | IDENT  /* could be bound variable or navigation */
        { $$ = ['identTODO', $1]; }
    | ROOT IDENT
        { $$ = ['navTODO', ['lit', '_root', [[]]], $2]; }
    | expression '.' IDENT
        { $$ = ['navTODO', $1, $3]; }
    | expression '=' expression
        { $$ = ['=', $1, $3]; }
    | expression IN expression
        { $$ = ['in', $1, $3]; }
    | '{' IDENT IN expression '|' expression '}'
        { $$ = ['filter', $4, [$2, $6]]; }
    ;

setLiteral
    : '{' '}'
        { $$ = ['setLiteralTODO', []]; }
    | '{' setLiteralMembers optComma '}'
        { $$ = ['setLiteralTODO', $2]; }
    ;

setLiteralMembers
    : singletonLiteral
        { $$ = [$1]; }
    | setLiteralMembers ',' singletonLiteral
        { $$ = $1.concat([$3]); }
    ;

optComma
    : ','
    |
    ;

singletonLiteral
    : stringLiteral  { $$ = $1; }
    | numberLiteral  { $$ = $1; }
    | booleanLiteral { $$ = $1; }
    ;

stringLiteral
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
    ;

numberLiteral
    : NUMBER
        {$$ = ['lit','_number',[Number(yytext)]];}
    ;

booleanLiteral
    : TRUE
        {$$ = ['lit','_bool',true];}
    | FALSE
        {$$ = ['lit','_bool',false];}
    ;

%%

/*
Portions derived from JSON Lint (https://github.com/zaach/jsonlint) under the following license:

Copyright (C) 2012 Zachary Carter

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
