#!/bin/bash

. ./path.sh ## set the paths in this file correctly!
. ./cmd.sh ## You'll want to change cmd.sh to something that will work on your system.
           ## This relates to the queue.

#check if the user wants to clean the project
local/clarin_pl_clean.sh

export nj=10 ##number of concurrent processes

# This is a shell script, but it's recommended that you run the commands one by
# one by copying and pasting into the shell.

#run some initial data preparation (look at the file for more details):
local/clarin_pl_data_prep.sh || exit 1;

#prepare the lang directory (with the word lists and initial FSTs)
utils/prepare_lang.sh data/local/dict "<unk>" data/local/lang data/lang || exit 1;

#make G.fst from the toy LM
( 
  cat data/local/lm.arpa | \
    grep -v "<s> <s>" | grep -v "</s> <s>" | grep -v "</s> </s>" | \
    arpa2fst - | fstprint | utils/eps2disambig.pl | utils/s2eps.pl | \
    fstcompile --isymbols=data/lang_test/words.txt \
      --osymbols=data/lang_test/words.txt --keep_isymbols=false \
      --keep_osymbols=false | \
    fstrmepsilon > data/lang_test/G.fst
)

ln -s ../lang_test/G.fst data/lang/G.fst

# Make MFCC features.
# mfccdir should be some place where you want to store MFCC features (225MB in size)
mfccdir=feat
for x in train test ; do 
 steps/make_mfcc.sh --cmd "$train_cmd" --nj $nj \
   data/$x exp/make_mfcc/$x $mfccdir || exit 1;
 steps/compute_cmvn_stats.sh data/$x exp/make_mfcc/$x $mfccdir || exit 1;
done

#train Monophone system
steps/train_mono.sh --nj $nj --cmd "$train_cmd" \
  data/train data/lang exp/mono0 || exit 1;

#test Monophone system
utils/mkgraph.sh --mono data/lang exp/mono0 exp/mono0/graph || exit 1;
steps/decode.sh --nj $nj --cmd "$decode_cmd" --beam 72 \
  exp/mono0/graph data/test exp/mono0/decode || exit 1;

#align using the Monophone system
steps/align_si.sh --nj $nj --cmd "$train_cmd" \
   data/train data/lang exp/mono0 exp/mono0_ali || exit 1;

#train initial Triphone system
steps/train_deltas.sh --cmd "$train_cmd" \
    2000 10000 data/train data/lang exp/mono0_ali exp/tri1 || exit 1;

#test initial Triphone system
utils/mkgraph.sh data/lang exp/tri1 exp/tri1/graph || exit 1;
steps/decode.sh --nj $nj --cmd "$decode_cmd" --beam 72 \
  exp/tri1/graph data/test exp/tri1/decode || exit 1;

#re-align using the initial Triphone system
steps/align_si.sh --nj $nj --cmd "$train_cmd" \
  data/train data/lang exp/tri1 exp/tri1_ali || exit 1;

#train tri2a, which is deltas + delta-deltas
steps/train_deltas.sh --cmd "$train_cmd" \
  2500 15000 data/train data/lang exp/tri1_ali exp/tri2a || exit 1;

#test tri2a
utils/mkgraph.sh data/lang exp/tri2a exp/tri2a/graph || exit 1;
steps/decode.sh --nj $nj --cmd "$decode_cmd" --beam 72 \
  exp/tri2a/graph data/test exp/tri2a/decode || exit 1;

#train tri2b, which is tri2a + LDA
steps/train_lda_mllt.sh --cmd "$train_cmd" \
   --splice-opts "--left-context=3 --right-context=3" \
   2500 15000 data/train data/lang exp/tri1_ali exp/tri2b || exit 1;

#test tri2b
utils/mkgraph.sh data/lang exp/tri2b exp/tri2b/graph || exit 1;
steps/decode.sh --nj $nj --cmd "$decode_cmd" --beam 72 \
  exp/tri2b/graph data/test exp/tri2b/decode || exit 1;


#re-align tri2b system
steps/align_si.sh  --nj $nj --cmd "$train_cmd" \
  --use-graphs true data/train data/lang exp/tri2b exp/tri2b_ali  || exit 1;


#from 2b system, train 3b which is LDA + MLLT + SAT.
steps/train_sat.sh --cmd "$train_cmd" \
  2500 15000 data/train data/lang exp/tri2b_ali exp/tri3b || exit 1;

#test tri3b
utils/mkgraph.sh data/lang exp/tri3b exp/tri3b/graph || exit 1;
steps/decode_fmllr.sh --nj $nj --cmd "$decode_cmd" --beam 72 \
  exp/tri3b/graph data/test exp/tri3b/decode || exit 1;


#increase the number of mixtures
steps/mixup.sh --cmd "$train_cmd" \
   20000 data/train data/lang exp/tri3b exp/tri3b_20k || exit 1;

#test the larger model
steps/decode_fmllr.sh --cmd "$decode_cmd" --beam 72 --nj $nj \
   exp/tri3b/graph data/test exp/tri3b_20k/decode  || exit 1;

#from 3b system, align all data
steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" \
  data/train data/lang exp/tri3b exp/tri3b_ali || exit 1;

#train MMI on tri3b (LDA+MLLT+SAT)
steps/make_denlats.sh --nj $nj --cmd "$train_cmd" \
  --transform-dir exp/tri3b_ali data/train data/lang exp/tri3b \
  exp/tri3b_denlats || exit 1;
steps/train_mmi.sh --cmd "$train_cmd" data/train data/lang exp/tri3b_ali exp/tri3b_denlats exp/tri3b_mmi || exit 1;

#test MMI
steps/decode_fmllr.sh --nj $nj --cmd "$decode_cmd" --beam 72 \
  --alignment-model exp/tri3b/final.alimdl --adapt-model exp/tri3b/final.mdl \
  exp/tri3b/graph data/test exp/tri3b_mmi/decode || exit 1;

# Getting results [see RESULTS file]
for x in exp/*/decode*; do [ -d $x ] && grep WER $x/wer_* | utils/best_wer.sh; done
