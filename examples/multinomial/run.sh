#!/usr/bin/env bash
set -eu

# A dummy program that validates the dynamic-scope multinomial variables.
# Has 2 variables:
#   m1=(a,b,c), m2=(b,c,d)
#
# Has 3 factors:
#
# f1(x) := 5 if x = 'd'
#
# f2(x, y) := 5 if x == y
#
# f3(x, y) := -5 if x == 'b' and y == 'b'
#
# This script is runnable alone.
#

cd "$(dirname "$0")"

# Generate db.url
echo "postgresql://localhost/deepdive_multinomial_$USER" > db.url

# Generate app.ddlog
echo '
# DO NOT EDIT: generated by run.sh
test_multinomial?(
  @key @distributed_by doc_id text,
  @key mention_id text,
  loc_id text
).

test_bad_factor(loc_id1 text, loc_id2 text).

is_d_factor(loc_id text).

# First factor gives a prior to value d
@weight(3)
test_multinomial(doc_id, mid, loc_id) :- is_d_factor(loc_id).

# Second factor boosts same values
@weight(5)
test_multinomial(doc_id, mid1, loc_id) ^ test_multinomial(doc_id, mid2, loc_id) :-
  [mid1 < mid2].

# Third factor punishes value combination "b, b" since it appears in test_bad_factor.
@weight(-5)
test_multinomial(doc_id, mid1, loc_id1) ^ test_multinomial(doc_id, mid2, loc_id2) :-
  test_bad_factor(loc_id1, loc_id2).
' > app.ddlog

echo 'deepdive.sampler.sampler_args: "-l 0 -s 1 -i 500 --alpha 0.1 -c 0"' > deepdive.conf

# Create necessary files
mkdir -p input
touch input/test_multinomial.tsv
touch input/test_bad_factor.tsv
touch input/is_d_factor.tsv

export DEEPDIVE_PLAN_EDIT=false
deepdive compile
deepdive mark todo process/init/app
# if you don't want to erase the database:
#deepdive mark done process/init/app

# Initialize tables
deepdive do test_multinomial
deepdive do test_bad_factor
deepdive do is_d_factor

# manually create two variables
deepdive sql "INSERT INTO test_multinomial(doc_id, mention_id, loc_id) VALUES
('test_doc', 'm1', 'a'),
('test_doc', 'm1', 'b'),
('test_doc', 'm1', 'c'),
('test_doc', 'm2', 'b'),
('test_doc', 'm2', 'c'),
('test_doc', 'm2', 'd');

insert into test_bad_factor values
('b', 'b'),
('a', 'c');

insert into is_d_factor values ('d');
"

# Run everything
deepdive do all

# Verify results:
deepdive sql "select * from test_multinomial_inference order by mention_id, expectation desc;"

echo 'Should pick m1=c and m2=c, but m2=d also gets a non-zero probability'

# Assertion
m1_prediction=$(deepdive sql eval "select loc_id from test_multinomial_inference where mention_id = 'm1' order by expectation desc limit 1")
m2_prediction=$(deepdive sql eval "select loc_id from test_multinomial_inference where mention_id = 'm2' order by expectation desc limit 1")
m2_d_prob=$(deepdive sql eval "select (expectation*100)::int from test_multinomial_inference where mention_id = 'm2' and loc_id='d'")
echo "m1 prediction: $m1_prediction"
echo "m2 prediction: $m2_prediction"
echo "m2=d expectation: 0.$m2_d_prob"

# Assertion: below should all return 0
[[ "$m1_prediction" == "c" ]]
[[ "$m2_prediction" == "c" ]]
[ $m2_d_prob -gt 10 ]

