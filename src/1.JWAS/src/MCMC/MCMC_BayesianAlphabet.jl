################################################################################
#MCMC for RR-BLUP, GBLUP, BayesABC, and conventional (no markers) methods
#
#GBLUP: pseudo markers are used.
#y = μ + a + e with mean(a)=0,var(a)=Gσ²=MM'σ² and G = LDL' <==>
#y = μ + Lα +e with mean(α)=0,var(α)=D*σ² : L orthogonal
#y2hat = cov(a2,a)*inv(var(a))*L*αhat =>
#      = (M2*M')*inv(MM')*L*αhat = (M2*M')*(L(1./D)L')(Lαhat)=(M2*M'*L(1./D))αhat
#
#Threshold trait:
#1)Sorensen and Gianola, Likelihood, Bayesian, and MCMC Methods in Quantitative
#Genetics
#2)Wang et al.(2013). Bayesian methods for estimating GEBVs of threshold traits.
#Heredity, 110(3), 213–219.
################################################################################
function MCMC_BayesianAlphabet(nIter,mme,df;
                     Rinv                       = false,
                     burnin                     = 0,
                     π                          = 0.0,
                     estimatePi                 = false,
                     estimate_variance          = false,
                     estimateScale              = false,
                     starting_value             = false,
                     outFreq                    = 1000,
                     methods                    = "BayesC",
                     output_samples_frequency   = 0,
                     update_priors_frequency    = 0,
                     output_file                = "MCMC_samples",
                     categorical_trait          = false)

    ############################################################################
    # Categorical Traits (starting values for maker effects defaulting to 0s)
    ############################################################################
    if categorical_trait == true
        category_obs,threshold = categorical_trait_setup(mme,starting_value)
    end
    ############################################################################
    # Working Variables
    # 1) samples at current iteration (starting values at the beginning, defaulting to zeros)
    # 2) posterior mean and variance at current iteration (zeros at the beginning)
    # 3) ycorr, phenotypes corrected for all effects
    ############################################################################
    #location parameters
    sol                = starting_value[1:size(mme.mmeLhs,1)]
    solMean, solMean2  = zero(sol),zero(sol)
    #residual variance
    if categorical_trait == false
        meanVare = meanVare2 = 0.0
    else
        mme.RNew = meanVare = meanVare2 = 1.0
    end
    #polygenic effects (A), e.g, Animal+ Maternal
    if mme.pedTrmVec != 0
       G0Mean,G0Mean2  = zero(mme.Gi),zero(mme.Gi)
    end
    #marker effects
    if mme.M != 0
        for Mi in mme.M
            mGibbs                              = GibbsMats(Mi.genotypes,Rinv)
            Mi.mArray,Mi.mRinvArray,Mi.mpRinvm  = mGibbs.xArray,mGibbs.xRinvArray,mGibbs.xpRinvx

            if Mi.method=="BayesB" #α=β.*δ
                Mi.G        = fill(Mi.G,Mi.nMarkers) #a scalar in BayesC but a vector in BayeB
            end
            if Mi.method=="BayesL"         #in the MTBayesLasso paper
                Mi.G   /= 8           #mme.M.G is the scale Matrix, Sigma
                Mi.scale /= 8
                gammaDist  = Gamma(1, 8) #8 is the scale parameter of the Gamma distribution (1/8 is the rate parameter)
                Mi.gammaArray = rand(gammaDist,mme.M.nMarkers)
            end
            Mi.α   = starting_value[(size(mme.mmeLhs,1)+1):end]
            if Mi.method=="GBLUP"
                D = GBLUP_setup(Mi)
            end
            Mi.β                               = copy(Mi.α)       #partial marker effeccts used in BayesB
            Mi.δ                               = ones(typeof(Mi.α[1]),Mi.nMarkers)  #inclusion indicator for marker effects
            Mi.meanAlpha,Mi.meanAlpha2         = zero(Mi.α),zero(Mi.α)  #marker effects
            Mi.meanDelta                       = zero(δ)                #inclusion indicator
            Mi.mean_pi,Mi.mean_pi2             = 0.0,0.0                #inclusion probability
            Mi.meanVara,Mi.meanVara2           = 0.0,0.0                #marker effect variances
            Mi.meanScaleVara,Mi.meanScaleVara2 = 0.0,0.0                #scale parameter for prior of marker effect variance
        end
    end
    #phenotypes corrected for all effects
    ycorr       = vec(Matrix(mme.ySparse)-mme.X*sol)
    if mme.M != 0 && α!=zero(α)
        ycorr = ycorr - mme.M.genotypes*α
    end
    ############################################################################
    #  SET UP OUTPUT MCMC samples
    ############################################################################
    if output_samples_frequency != 0
        outfile=output_MCMC_samples_setup(mme,nIter-burnin,output_samples_frequency,output_file)
    end
    ############################################################################
    # MCMC (starting values for sol (zeros);  mme.RNew; G0 are used)
    ############################################################################
    @showprogress "running MCMC for "*methods*"..." for iter=1:nIter
        ########################################################################
        # 0. Categorical traits (liabilities)
        ########################################################################
        if categorical_trait == true
            ycorr = categorical_trait_sample_liabilities(mme,ycorr,category_obs,threshold)
        end
        ########################################################################
        # 1.1. Non-Marker Location Parameters
        ########################################################################
        ycorr = ycorr + mme.X*sol
        if Rinv == false
            rhs = mme.X'ycorr
        else
            rhs = mme.X'Diagonal(Rinv)*ycorr
        end

        Gibbs(mme.mmeLhs,sol,rhs,mme.RNew)

        ycorr = ycorr - mme.X*sol
        ########################################################################
        # 1.2 Marker Effects
        ########################################################################
        if mme.M !=0
            for Mi in mme.M
                if Mi.method in ["BayesC","BayesB","BayesA"]
                    locus_effect_variances = (Mi.method == "BayesC" ? fill(Mi.G,Mi.nMarkers) : Mi.G)
                    BayesABC!(Mi,ycorr,mme.RNew,locus_effect_variances)
                elseif Mi.method =="RR-BLUP"
                    BayesC0!(Mi,ycorr,mme.RNew)
                elseif Mi.method == "BayesL"
                    BayesL!(Mi,ycorr,mme.RNew)
                elseif Mi.method == "GBLUP"
                    GBLUP!(Mi,ycorr,mme.Rnew,Rinv,D)
                end
                if estimatePi == true #method specific pi?
                    Mi.π = samplePi(Mi.nLoci, Mi.nMarkers)
                end
            end
        end
        ########################################################################
        # 2.1 Genetic Covariance Matrix (Polygenic Effects) (variance.jl)
        # 2.2 varainces for (iid) random effects;not required(empty)=>jump out
        ########################################################################
        if mme.MCMCinfo.estimate_variance == true
            sampleVCs(mme,sol)
            addVinv(mme)
        end
        ########################################################################
        # 2.3 Residual Variance
        ########################################################################
        if categorical_trait == false && mme.MCMCinfo.estimate_variance == true
            mme.ROld = mme.RNew
            mme.RNew = sample_variance(ycorr.* (Rinv!=false ? sqrt.(Rinv) : 1.0), length(ycorr), mme.df.residual, mme.scaleRes)
        end
        ########################################################################
        # 2.4 Marker Effects Variance
        ########################################################################
        if mme.M != 0 && mme.MCMCinfo.estimate_variance == true #methd specific estimate_variance
            for Mi in mme.M
                if Mi.method in ["BayesC","RR-BLUP"]
                    Mi.G  = sample_variance(α, nLoci, mme.df.marker, mme.M.scale)
                elseif Mi.method == "BayesB"
                    for j=1:mme.M.nMarkers
                        Mi.G[j] = sample_variance(β[j],1,mme.df.marker, mme.M.scale)
                    end
                elseif Mi.method == "BayesL"
                    ssq = 0.0
                    for i=1:size(α,1)
                        ssq += α[i]^2/Mi.gammaArray[i]
                    end
                    Mi.G = (ssq + mme.df.marker*Mi.scale)/rand(Chisq(nLoci+mme.df.marker))
                    # MH sampler of gammaArray (Appendix C in paper)
                    sampleGammaArray!(Mi.gammaArray,α,mme.M.G)
                elseif Mi.method == "GBLUP"
                    Mi.G  = sample_variance(α./sqrt.(D), Mi.nObs,mme.df.marker, Mi.scale)
                else
                    error("Sampling of marker effect variances is not available")
                end
            end
        end
        ########################################################################
        # 2.5 Update priors using posteriors (empirical) LATER
        ########################################################################
        if update_priors_frequency !=0 && iter%update_priors_frequency==0
            if mme.M!=0 && methods != "BayesB"
                mme.M.scale   = meanVara*(mme.df.marker-2)/mme.df.marker
            end
            if mme.pedTrmVec != 0
                mme.scalePed  = G0Mean*(mme.df.polygenic - size(mme.pedTrmVec,1) - 1)
            end
            mme.scaleRes  =  meanVare*(mme.df.residual-2)/mme.df.residual
            println("\n Update priors from posteriors.")
        end
        ########################################################################
        # 2.6 sample Scale parameter in prior for marker effect variances
        ########################################################################
        if estimateScale == true
            a = size(mme.M.G,1)*mme.df.marker/2   + 1
            b = sum(mme.df.marker ./ (2*mme.M.G )) + 1
            mme.M.scale = rand(Gamma(a,1/b))
        end
        ########################################################################
        # 3.1 Save MCMC samples
        ########################################################################
        if iter>burnin && (iter-burnin)%output_samples_frequency == 0
            if mme.M != 0
                output_MCMC_samples(mme,sol,mme.RNew,(mme.pedTrmVec!=0 ? inv(mme.Gi) : false),mme.M.π,mme.M.α,mme.M.G,outfile)
            else
                output_MCMC_samples(mme,sol,mme.RNew,(mme.pedTrmVec!=0 ? inv(mme.Gi) : false),false,false,false,outfile)
            end

            nsamples = (iter-burnin)/output_samples_frequency
            solMean   += (sol - solMean)/nsamples
            solMean2  += (sol .^2 - solMean2)/nsamples
            meanVare  += (mme.RNew - meanVare)/nsamples
            meanVare2 += (mme.RNew .^2 - meanVare2)/nsamples

            if mme.pedTrmVec != 0
                G0Mean  += (inv(mme.Gi)  - G0Mean )/nsamples
                G0Mean2 += (inv(mme.Gi) .^2  - G0Mean2 )/nsamples
            end
            if mme.M != 0
                for Mi in mme.M
                    Mi.meanAlpha  += (Mi.α - Mi.meanAlpha)/nsamples
                    Mi.meanAlpha2 += (Mi.α .^2 - Mi.meanAlpha2)/nsamples
                    Mi.meanDelta  += (Mi.δ - Mi.meanDelta)/nsamples

                    if Mi.estimatePi == true
                        Mi.mean_pi += (Mi.π-Mi.mean_pi)/nsamples
                        Mi.mean_pi2 += (Mi.π .^2-Mi.mean_pi2)/nsamples
                    end
                    if Mi.method != "BayesB"
                        Mi.meanVara += (Mi.G - Mi.meanVara)/nsamples
                        Mi.meanVara2 += (Mi.G .^2 - Mi.meanVara2)/nsamples
                    end
                    if estimateScale == true
                        Mi.meanScaleVara += (Mi.scale - Mi.meanScaleVara)/nsamples
                        Mi.meanScaleVara2 += (Mi.scale .^2 - Mi.meanScaleVara2)/nsamples
                    end
                end
            end
        end

        ########################################################################
        # 3.2 Printout
        ########################################################################
        if iter%outFreq==0 && iter>burnin
            println("\nPosterior means at iteration: ",iter)
            println("Residual variance: ",round(meanVare,digits=6))
        end
    end

    ############################################################################
    # After MCMC
    ############################################################################
    if output_samples_frequency != 0
      for (key,value) in outfile
        close(value)
      end
    end
    if methods == "GBLUP"
        mv(output_file*"_marker_effects_variances.txt",output_file*"_genetic_variance(REML).txt")
    end
    output=output_result(mme,output_file,
                         solMean,meanVare,
                         mme.pedTrmVec!=0 ? G0Mean : false,
                         mme.M != 0 ? mme.M.meanAlpha : false,
                         mme.M != 0 ? mme.M.meanDelta : false,
                         mme.M != 0 ? mme.M.meanVara : false,
                         mme.M != 0 ? estimatePi : false,
                         mme.M != 0 ? mme.M.mean_pi : false,
                         mme.M != 0 ? estimateScale : false,
                         mme.M != 0 ? mme.M.meanScaleVara : false,
                         solMean2,meanVare2,
                         mme.pedTrmVec!=0 ? mme.M.G0Mean2 : false,
                         mme.M != 0 ? mme.M.meanAlpha2 : false,
                         mme.M != 0 ? mme.M.meanVara2 : false,
                         mme.M != 0 ? mme.M.mean_pi2 : false,
                         mme.M != 0 ? mme.M.meanScaleVara2 : false)
    return output
end
