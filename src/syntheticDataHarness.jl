###
# Test using simulated data
#
# For increasing K, simulate datasets and performance 
# of various methods SAA, Alpha LOO, and Alpha OR
###
using Distributions, Random, DelimitedFiles
include("../src/JS_SAA_main.jl")

#supp_full, ps_full are d x K matrices with true info per problem
#adds new subproblems in order appear in files
#s is the service level, N is the average amount of data per problem
function convInKtest(numRuns, K_grid, supp_full, ps_full, outPath, N_grid, s; 
						usePoisson=true, seed=8675309, alpha_max = 180, alpha_len=120, 
						allCV=false, onlyShrunken=false)
	Random.seed!(seed)
	Kmax = maximum(K_grid)
	@assert Kmax <= size(supp_full, 2) "K_grid exceeds available subproblems"
	@assert size(supp_full) == size(ps_full) "supp_full and ps_full have incompatible dimensions"

	d = size(supp_full, 1)

	#For safety, trim inputs to size Kmax
	supp_full = view(supp_full, 1:d, 1:Kmax)
	ps_full = view(ps_full, 1:d, 1:Kmax)

	p0 = ones(d)/d
	alpha_grid = range(0., stop=alpha_max, length=alpha_len)
	Gamma_grid = range(0, stop = (1-s), length=51)
	theta2_grid = range(1e-6, stop=3, length=20)
	mu_grid = range(1e-6, stop=1, length=20)

	#set up output file
	f = open("$(outPath).csv", "w")
	writedlm(f, ["Run" "K" "d" "N" "Method" "TruePerf" "time" "alpha"], ',')

	#generate all Kmax subproblems upfront and store in memory
	cs_full = JS.getNewsVendorCosts(supp_full, s, Kmax)
	xs_full = JS.genSSAAtrainers(supp_full, s)
	xsKS_full = JS.genKSTrainers(supp_full, s, Kmax, :crossVal)

	lam_full = ones(Kmax)

	for (iRun, N) = Iterators.product(1:numRuns, N_grid)
		#simulate data for the run
		Nhats_full = usePoisson ? rand(Poisson(N), Kmax) : N * ones(Int, Kmax) 

		#for now, cludge the Nhatk == 0 issue
		Nhats_full[Nhats_full .== 0] .= 1
		mhats_full = JS.sim_path(ps_full, Nhats_full)

		for K in K_grid
			#Take views on evrything for simplicity
			lams = view(lam_full, 1:K)
			supp = view(supp_full, 1:d, 1:K)
			ps = view(ps_full, 1:d, 1:K)
			Nhats = view(Nhats_full, 1:K)
			mhats = view(mhats_full, 1:d, 1:K)
			cs = view(cs_full, 1:d, 1:K)
			xs = view(xs_full, 1:K)
			xsKS = view(xsKS_full, 1:K)

			#for data-driven shrinkage anchor
			#@VG Consider changing below to get_GM_anchor
			phat_avg = vec(mean(mhats ./ Nhats', dims=2))

			#Compute the full-info value once for reference
			if iRun == 1
				t = 
				  @elapsed full_info = JS.zstar(xs, cs, ps, lams)
				writedlm(f, [1 K d N "FullInfo" full_info t 0.], ',')
			end

			#SAA
			t = 
			  @elapsed perf_SAA = JS.zbar(xs, cs, mhats, ps, lams, (p0, 0.))
			writedlm(f, [iRun K d N "SAA" perf_SAA t 0.0], ',')

			#Gen the Oracle cost with 1/d anchor
			t = 
			  @elapsed alphaOR, min_indx, or_alpha_curve = JS.oracle_alpha(xs, cs, mhats, ps, lams, p0, alpha_grid)
			writedlm(f, [iRun K d N "Oracle" or_alpha_curve[min_indx] t alphaOR], ',')

			#Gen the LOO cost with 1/d anchor
			t = 
			  @elapsed alphaLOO, min_indx, looUnsc_curve = JS.loo_alpha(xs, cs, mhats, p0, alpha_grid)
			writedlm(f, [iRun K d N "LOO_unif" or_alpha_curve[min_indx] t alphaLOO], ',')

			if !onlyShrunken
				#Gen the 5-Fold Cost with 1/d anchor
				t = 
				  @elapsed alphaCV, min_indx, CVUnsc_curve = JS.cv_alpha(xs, cs, mhats, p0, alpha_grid, 5)
				writedlm(f, [iRun K d N "CV5_unif" or_alpha_curve[min_indx] t alphaCV], ',')

				if allCV
					#Gen the 2-Fold Cost with 1/d anchor
					t = 
					  @elapsed alphaCV, min_indx, CVUnsc_curve = JS.cv_alpha(xs, cs, mhats, p0, alpha_grid, 2)
					writedlm(f, [iRun K d N "CV2_unif" or_alpha_curve[min_indx] t alphaCV], ',')


					#Gen the 10-Fold Cost with 1/d anchor
					t = 
					  @elapsed alphaCV, min_indx, CVUnsc_curve = JS.cv_alpha(xs, cs, mhats, p0, alpha_grid, 10)
					writedlm(f, [iRun K d N "CV10_unif" or_alpha_curve[min_indx] t alphaCV], ',')
				end

				##MSE version of alpha
				t = 
				  @elapsed alphaMSE, min_indx = JS.mse_estimates(mhats, supp, p0, alpha_grid)
				writedlm(f, [iRun K d N "MSE" or_alpha_curve[min_indx] t alphaMSE], ',')
			end

			#Gen the Oracle cost with GM Anchor
			t = 
			  @elapsed alphaOR_GM, min_indx, or_alpha_curve_GM = JS.oracle_alpha(xs, cs, mhats, ps, lams, phat_avg, alpha_grid)
			writedlm(f, [iRun K d N "OraclePhat" or_alpha_curve_GM[min_indx] t alphaOR_GM], ',')

			#Gen the LOO cost with the GM Anchor
			t = 
			  @elapsed alphaLOO, min_indx, looUnsc_curve = JS.loo_alpha(xs, cs, mhats, phat_avg, alpha_grid)
			writedlm(f, [iRun K d N "LOO_avg" or_alpha_curve_GM[min_indx] t alphaLOO], ',')
			temp_GM = looUnsc_curve[min_indx]

			if !onlyShrunken
				#Gen the CV5 cost with the GM Anchor
				t = 
				  @elapsed alphaCV, min_indx, CVUnsc_curve = JS.cv_alpha(xs, cs, mhats, phat_avg, alpha_grid, 5)
				writedlm(f, [iRun K d N "CV5_avg" or_alpha_curve_GM[min_indx] t alphaCV], ',')

				if allCV
					#Gen the CV2 cost with the GM Anchor
					t = 
					  @elapsed alphaCV, min_indx, CVUnsc_curve = JS.cv_alpha(xs, cs, mhats, phat_avg, alpha_grid, 2)
					writedlm(f, [iRun K d N "CV2_avg" or_alpha_curve_GM[min_indx] t alphaCV], ',')

					#Gen the CV10 cost with the GM Anchor
					t = 
					  @elapsed alphaCV, min_indx, CVUnsc_curve = JS.cv_alpha(xs, cs, mhats, phat_avg, alpha_grid, 10)
					writedlm(f, [iRun K d N "CV10_avg" or_alpha_curve_GM[min_indx] t alphaCV], ',')
				end

				##MSE version of alpha with GM
				t = 
				  @elapsed alphaMSe, min_indx = JS.mse_estimates(mhats, supp, phat_avg, alpha_grid)
				writedlm(f, [iRun K d N "MSE_GM" or_alpha_curve_GM[min_indx] t alphaMSE], ',')

				##KS version with cross-val
				t = 
				  @elapsed perf_KS = JS.zbar(xsKS, cs, mhats, ps, lams, (Gamma_grid, 5))
				writedlm(f, [iRun K d N "KS" perf_KS t 0.0], ',')
			end

			## Optimizing a beta distribution anchor
			t = 
			  @elapsed alphaLOO, p0LOO, loo_val = JS.loo_betaAnchor(xs, cs, mhats, alpha_grid, theta2_grid, mu_grid)
			true_perf = JS.zbar(xs, cs, mhats, ps, lams, (p0LOO, alphaLOO))
			writedlm(f, [iRun K d N "BetaOptLOO" true_perf t alphaLOO], ',')
			println()
			println("----Beta %Improv LOO\t", 1- loo_val/temp_GM, "------")
			println()

			t = 
			  @elapsed alphaOR, p0OR, or_val = JS.oracle_betaAnchor(xs, cs, mhats, ps, lams, alpha_grid, theta2_grid, mu_grid)
		
			writedlm(f, [iRun K d N "BetaOptOR" or_val t alphaOR], ',')

		end  #end K Loop
		flush(f)
	end #end run loop 
	close(f)
	"$(outPath).csv"
end #end function 
