#!/bin/bash
# Copyright 2012  Johns Hopkins University (Author: Daniel Povey)
# Apache 2.0
#
# Adapted from steps/align_fmllr.sh

# Computes training alignments; assumes features are (LDA+MLLT or delta+delta-delta)
# + fMLLR (probably with SAT models).
# It first computes an alignment with the final.alimdl (or the final.mdl if final.alimdl
# is not present), then does 2 iterations of fMLLR estimation.

# If you supply the --use-graphs option, it will use the training
# graphs from the source directory (where the model is).  In this
# case the number of jobs must match the source directory.


# Begin configuration section.  
stage=0
nj=4
cmd=run.pl
use_graphs=false
# Begin configuration.
scale_opts="--transition-scale=1.0 --acoustic-scale=0.1 --self-loop-scale=0.1"
beam=10
#retry_beam=40
retry_beam=100
careful=false
boost_silence=1.0 # factor by which to boost silence during alignment.
fmllr_update_type=full
# End configuration options.

echo "$0 $@"  # Print the command line for logging

[ -f path.sh ] && . ./path.sh # source the path.
. parse_options.sh || exit 1;

#if [ $# != 4 ]; then
if [ $# != 5 ]; then
   echo "usage: local/align_fmllr_g_pt.sh <data-dir> <lang-dir> <src-dir> <align-dir>"
   echo "e.g.:  local/align_fmllr_g_pt.sh data/train data/lang exp/tri1 exp/tri1_ali"
   echo "main options (for others, see top of script file)"
   echo "  --config <config-file>                           # config containing options"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --use-graphs true                                # use graphs in src-dir"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   echo "  --fmllr-update-type (full|diag|offset|none)      # default full."
   exit 1;
fi

data=$1
lang=$2
srcdir=$3
dir=$4
dir_fsts=$5 # fsts of probabilistic transcriptions

oov=`cat $lang/oov.int` || exit 1;
silphonelist=`cat $lang/phones/silence.csl` || exit 1;
sdata=$data/split$nj

mkdir -p $dir/log
echo $nj > $dir/num_jobs
[[ -d $sdata && $data/feats.scp -ot $sdata ]] || split_data.sh $data $nj || exit 1;

cp $srcdir/{tree,final.mdl} $dir || exit 1;
cp $srcdir/final.alimdl $dir 2>/dev/null
cp $srcdir/final.occs $dir;
splice_opts=`cat $srcdir/splice_opts 2>/dev/null` # frame-splicing options.
cp $srcdir/splice_opts $dir 2>/dev/null # frame-splicing options.
cmvn_opts=`cat $srcdir/cmvn_opts 2>/dev/null`
cp $srcdir/cmvn_opts $dir 2>/dev/null # cmn/cmvn option.
delta_opts=`cat $srcdir/delta_opts 2>/dev/null`
cp $srcdir/delta_opts $dir 2>/dev/null

if [ -f $srcdir/final.mat ]; then feat_type=lda; else feat_type=delta; fi
echo "$0: feature type is $feat_type"

case $feat_type in
  delta) sifeats="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | add-deltas $delta_opts ark:- ark:- |";;
  lda) sifeats="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $srcdir/final.mat ark:- ark:- |"
    cp $srcdir/final.mat $dir
    cp $srcdir/full.mat $dir 2>/dev/null
   ;;
  *) echo "Invalid feature type $feat_type" && exit 1;
esac

## Set up model and alignment model.
mdl=$srcdir/final.mdl
if [ -f $srcdir/final.alimdl ]; then
  alimdl=$srcdir/final.alimdl
else
  alimdl=$srcdir/final.mdl
fi
[ ! -f $mdl ] && echo "$0: no such model $mdl" && exit 1;
alimdl_cmd="gmm-boost-silence --boost=$boost_silence `cat $lang/phones/optional_silence.csl` $alimdl - |"
mdl_cmd="gmm-boost-silence --boost=$boost_silence `cat $lang/phones/optional_silence.csl` $mdl - |"


## Work out where we're getting the graphs from.
if $use_graphs; then
  echo "unexpected, see local/align_fmllr_g_pt.sh line 99" && exit 1;
:<<'END'
  [ "$nj" != "`cat $srcdir/num_jobs`" ] && \
    echo "$0: you specified --use-graphs true, but #jobs mismatch." && exit 1;
  [ ! -f $srcdir/fsts.1.gz ] && echo "No graphs in $srcdir" && exit 1;
  graphdir=$srcdir
END
else
  graphdir=$dir
  if [ $stage -le 0 ]; then
    echo "$0: compiling training graphs"
    #tra="ark:utils/sym2int.pl --map-oov $oov -f 2- $lang/words.txt $sdata/JOB/text|";   
    #$cmd JOB=1:$nj $dir/log/compile_graphs.JOB.log  \
    #  compile-train-graphs $dir/tree $dir/final.mdl  $lang/L.fst "$tra" \
    #    "ark:|gzip -c >$dir/fsts.JOB.gz" || exit 1;

    #dir_fsts="/export/ws15-pt-data/cliu/data/phonelattices/monophones/engg2p/mandarin_epsilon_3-sym_fixed"
    #dir_fsts="/export/ws15-pt-data/cliu/data/phonelattices/monophones/trainedp2let/HG_SW_UR_DT_AR_MDdecode-rmeps"
    $cmd JOB=1:$nj $dir/log/text_pt.JOB.log \
      cut -f1 "$sdata/JOB/text" \| awk -v dir_fsts=$dir_fsts \
      '{key=value=$1; value=value".lat.fst"; print key"\t"dir_fsts"/"value}' \
      \> "$sdata/JOB/text.pt" || exit 1;

      #'{key=value=$1; value=value".saus.fst"; print key"\t"dir_fsts"/"value}' \

    $cmd JOB=1:$nj $dir/log/compile_graphs.JOB.log \
      compile-train-graphs-fsts-pt --read-disambig-syms=$lang/phones/disambig_new.int \
      --batch-size=1 --transition-scale=1.0 --self-loop-scale=0.1 $dir/tree $dir/final.mdl  $lang/L_disambig_new.fst  \
      "ark:cat $sdata/JOB/text.pt|" "ark:|gzip -c >$dir/fsts.JOB.gz" || exit 1;
      #compile-train-graphs-fsts-pt --read-disambig-syms=$lang/phones/disambig.int \
      #--batch-size=1 --transition-scale=1.0 --self-loop-scale=0.1 $dir/tree $dir/final.mdl  $lang/L_disambig.fst  \
  fi
fi


if [ $stage -le 1 ]; then
  echo "$0: aligning data in $data using $alimdl and speaker-independent features."
  $cmd JOB=1:$nj $dir/log/align_pass1.JOB.log \
    gmm-align-compiled $scale_opts --beam=$beam --retry-beam=$retry_beam --careful=$careful "$alimdl_cmd" \
    "ark:gunzip -c $graphdir/fsts.JOB.gz|" "$sifeats" "ark:|gzip -c >$dir/pre_ali.JOB.gz" || exit 1;
fi

if [ $stage -le 2 ]; then
  echo "$0: computing fMLLR transforms"
  if [ "$alimdl" != "$mdl" ]; then
    $cmd JOB=1:$nj $dir/log/fmllr.JOB.log \
      ali-to-post "ark:gunzip -c $dir/pre_ali.JOB.gz|" ark:- \| \
      weight-silence-post 0.0 $silphonelist $alimdl ark:- ark:- \| \
      gmm-post-to-gpost $alimdl "$sifeats" ark:- ark:- \| \
      gmm-est-fmllr-gpost --fmllr-update-type=$fmllr_update_type \
      --spk2utt=ark:$sdata/JOB/spk2utt $mdl "$sifeats" \
      ark,s,cs:- ark:$dir/trans.JOB || exit 1;
  else
    $cmd JOB=1:$nj $dir/log/fmllr.JOB.log \
      ali-to-post "ark:gunzip -c $dir/pre_ali.JOB.gz|" ark:- \| \
      weight-silence-post 0.0 $silphonelist $alimdl ark:- ark:- \| \
      gmm-est-fmllr --fmllr-update-type=$fmllr_update_type \
      --spk2utt=ark:$sdata/JOB/spk2utt $mdl "$sifeats" \
      ark,s,cs:- ark:$dir/trans.JOB || exit 1;
  fi
fi

feats="$sifeats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$dir/trans.JOB ark:- ark:- |"

if [ $stage -le 3 ]; then
  echo "$0: doing final alignment."
  #$cmd JOB=1:$nj $dir/log/align_pass2.JOB.log \
  #  gmm-align-compiled $scale_opts --beam=$beam --retry-beam=$retry_beam --careful=$careful "$mdl_cmd" \
  #  "ark:gunzip -c $graphdir/fsts.JOB.gz|" "$feats" "ark:|gzip -c >$dir/ali.JOB.gz" || exit 1;

  #maxactive=7000; beam=20.0; lattice_beam=7.0; acwt=0.083333;
  #maxactive=7000; beam=20.0; lattice_beam=3.0; acwt=0.083333;
  maxactive=20000; beam=100.0; lattice_beam=3.0; acwt=0.083333;
  #$cmd JOB=1:$nj $dir/log/align_pass2.JOB.log \
    #gmm-latgen-faster --max-active=$maxactive --beam=$beam --lattice-beam=$lattice_beam --acoustic-scale=$acwt \
      #--allow-partial=true --word-symbol-table=$lang/words.txt \
      #$dir/final.mdl "ark:gunzip -c $dir/fsts.JOB.gz|" "$feats" ark:- \| \
      #lattice-to-post --acoustic-scale=$acwt ark:- "ark:|gzip -c >$dir/post.JOB.gz"
   mkdir -p $dir/decode_train
   $cmd JOB=1:$nj $dir/log/align_pass2.JOB.log \
    gmm-latgen-faster --max-active=$maxactive --beam=$beam --lattice-beam=$lattice_beam --acoustic-scale=$acwt \
      --allow-partial=true --word-symbol-table=$lang/words.txt \
      $dir/final.mdl "ark:gunzip -c $dir/fsts.JOB.gz|" "$feats" "ark:|gzip -c > $dir/decode_train/lat.JOB.gz"
   $cmd JOB=1:$nj $dir/log/lat-to-post.JOB.log \
    lattice-to-post --acoustic-scale=$acwt "ark:gunzip -c $dir/decode_train/lat.JOB.gz|"  "ark:|gzip -c >$dir/post.JOB.gz"
   echo $nj > $dir/decode_train/num_jobs 
fi

rm $dir/pre_ali.*.gz

echo "$0: done aligning data."

utils/summarize_warnings.pl $dir/log

exit 0;
