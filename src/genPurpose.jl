## General purpose functions 

#User is expected to pass functions
#x_k(mhatk, hyperparam)  : provides a solution with data mhatk using hyperparam (e.g., p0, alpha)
#c_ik(x)      		
#These are often collected into arrays of functions
# xs			: [x_k for k = 1:K]
# c_k  			: [c_ik for i = 1:d]
# cs			: (d, K) Matrix with elements c_ik

#General purpose functions
###
function shrink(phat_k, p0, alpha, Nhat_k; alphaMax = 1e10)
	if Nhat_k == 0 || alpha > alphaMax
		return p0
	end
	@. alpha * p0 / (Nhat_k + alpha) + Nhat_k * phat_k / (Nhat_k + alpha)
end

#takes un-noramlized counts
#assumes out is correctly sized no bounds checking!
function _shrink!(mhat_k, p0, alpha, Nhat_k, out; alphaMax = 1e10)
	if Nhat_k == 0 || alpha > alphaMax
		return p0
	end
	for i = 1:length(p0)
		@inbounds out[i] = alpha * p0[i] / (Nhat_k + alpha) + mhat_k[i] / (Nhat_k + alpha)
	end
	out
end

#need to be careful because some problems may have zero data
function get_GM_anchor(mhats)
	Nhats = vec(sum(mhats, dims=1))
	non_zero_indx = Nhats .> 0
	vec(mean(mhats[:, non_zero_indx] ./ Nhats[non_zero_indx]', dims=2))
end

function sim_path(p_k, N::Int)
    mhats_k = zeros(length(p_k))
    
    if N == 0 #allow simulating zero data points
    	return mhats_k
    end

    for j in rand(Categorical(p_k), N)
        mhats_k[j] += 1
    end
    mhats_k
end

#ps is a matrix of pk
function sim_path(ps, Nhats)
    K = size(ps, 2)
    out = zeros(size(ps))
    for k = 1:K
        out[:, k] = sim_path(ps[:, k], Nhats[k])
    end
    out    
end

#empirical bayes moment-matched estimates. 
#returns p0, alpha0
#VG this method does not seem to consistenty yield alpha in [0, 1]
function eb_mm_estimates(mhats)
	Nhats = sum(mhats, dims=1)
	p0 = mean(mhats ./ Nhats, dims=2)
	K = size(mhats, 2)

	C0 = sum(mhats.^2)/K
	sq_norm_p0 = norm(p0)^2
	Nbar = mean(Nhats)
	var_n = mean( @.(Nhats^2 - Nhats) )

	alpha0 = C0 - sq_norm_p0 * var_n - Nbar
	@assert alpha0 > 0 "Moment matching fails"
	alpha0 /= (1 - sq_norm_p0) / var_n
	alpha0 = 1 / alpha0 - 1

	return p0, alpha0
end

#solves an approximation to the Apriori MSE equation for alpha
#for large K this is like AlphaOR for MSE
#for now, super lazy and just search a grid.
#returns AlphaEstimate, minimizingAlphaIndex 
function mse_estimates(mhats, supps, p0, alpha_grid)
	K = size(mhats, 2)
	Nhats = sum(mhats, dims=1)
	phats = mhats ./ Nhats
	mu0s = vec(p0' * supps)

	#summary statistics
	muhats = Vector{Float64}(undef, K)
	sigmas = Vector{Float64}(undef, K)
	mse0 = Vector{Float64}(undef, K)
	for k = 1:K
		muhats[k] = dot(phats[:, k], supps[:, k])
		sigmas[k] = dot(phats[:, k], supps[:, k].^2) - muhats[k]^2
		mse0[k] = dot(phats[:, k], @.((supps[:, k] - mu0s[k])^2) )
	end

	#worker function
	function mse(a)
		out = 0.
		for k = 1:K
			out += (Nhats[k] - a^2) / (Nhats[k] + a)^2 * sigmas[k]
			out += ( a / (a + Nhats[k]) )^2 * mse0[k]
		end
		out/K
	end
	out = map(mse, alpha_grid)
	alpha_grid[argmin(out)], argmin(out)
end

#kth element of true perf
function z_k(x_k, c_k, mhat_k, ps_k, lam_k, lamavg, hyper_param)
	x = x_k(mhat_k, hyper_param)
	cs = map(c_ik -> c_ik(x), c_k)
	lam_k/lamavg * dot(ps_k, cs) 
end

#actually returns zLOO_k * N * lamavg
function zLOO_k_unsc(x_k, c_k, mhat_k, hyper_param)
	#only compute for terms where mhat_k[i] > 0
	out = 0.
	for i = 1:length(mhat_k)
		if mhat_k[i] > 0
			mhat_k[i] -= 1	
		    x = x_k(mhat_k, hyper_param)
		    mhat_k[i] += 1
		    out += mhat_k[i] * c_k[i](x)
		end
	end
	out
end


#average true performance
#hyper_param = p0, alpha
function zbar(xs, cs, mhats, ps, lams, hyper_param)
	lamavg = mean(lams)
	K = size(cs, 2)
	out = 0.
	#VG maybe change this to a more numerically stable way to do avg?
	for k = 1:K
		out += z_k(xs[k], cs[:, k], mhats[:, k], ps[:, k], lams[k], lamavg, hyper_param)
	end
	out/K
end

#full-info for scaling/comparison
#uses the fact that data scale doesn't matter.
#Only works for the regular xs (which is lame)
zstar(xs, cs, ps, lams) = zbar(xs, cs, ps, ps, lams, (ps[:, 1], 0.))

function zLOObar_unsc(xs, cs, mhats, hyper_param)
	K = size(cs, 2)
	out = 0.
	for k = 1:K
		@inbounds @views out += zLOO_k_unsc(xs[k], cs[:, k], mhats[:, k], hyper_param)
	end
	out /K
end

#actually returns N lam_avg * ZCVbar
function zCVbar_unsc(xs, cs, cv_data, hyper_param)
	out = 0.
	numFolds = length(cv_data)
	lams = ones(length(xs))

	for fold = 1:numFolds
		#form the training set and testing distribution
		#be careful about empty problems in testing
		train_data = sum(cv_data[setdiff(1:numFolds, fold)])

		#dispatch to the zbar method, again using scaling not important
		out += zbar(xs, cs, train_data, cv_data[fold], lams, hyper_param)
	end
	return out
end

#returns alphaOR, minimizingAlphaIndex, curveInAlpha
function oracle_alpha(xs, cs, mhats, ps, lams, p0, alpha_grid)
	alphaOR = 0.
	jstar = -1
	best_val = Inf
	out = zeros(length(alpha_grid))
	for (j, alpha) in enumerate(alpha_grid)
		out[j] = zbar(xs, cs, mhats, ps, lams, (p0, alpha))
		if out[j] < best_val
			jstar = j
			alphaOR = alpha
			best_val = out[j]
		end
	end
	return alphaOR, jstar, out
end	

#returns alphaLOO, jstar, and cuveInAlpha_unsc
function loo_alpha(xs, cs, mhats, p0, alpha_grid)
	alphaLOO = 0.
	jstar = -1
	best_val = Inf
	out = zeros(length(alpha_grid))

	for (j, alpha) in enumerate(alpha_grid)
		out[j] = zLOObar_unsc(xs, cs, mhats, (p0, alpha))
		if out[j] < best_val
			jstar = j
			alphaLOO = alpha
			best_val = out[j]
		end
	end
	return alphaLOO, jstar, out
end	

function cv_alpha(xs, cs, mhats, p0, alpha_grid, numFolds)
	#divy up the data
	cv_data = split_cv(mhats, numFolds)

	alphaCV = 0.
	jstar = -1
	best_val = Inf
	out = zeros(length(alpha_grid))
	for (j, alpha) in enumerate(alpha_grid)
		out[j] = zCVbar_unsc(xs, cs, cv_data, (p0, alpha))
		if out[j] < best_val
			jstar = j
			alphaCV = alpha
			best_val = out[j]
		end
	end
	return alphaCV, jstar, out
end	



#########
#Functions to optimize anchor among beta distributions
########
#perform a naive discretization into d+1 points (d bins)
#p_i = Prob((i-1)/(d) <= Beta i <= i /d ) i = 1:d
#assumes p0_out is of size d
function formBetaAnchor!(theta1, theta2, d, p0_out)
	@assert length(p0_out) == d "p0_out must be of length $d"
	dist = Distributions.Beta(theta1, theta2)
	for i = 1:d
		p0_out[i] = cdf(dist, i/d) - cdf(dist, (i-1)/d)
	end
	p0_out
end

#Fits a beta(theta1, theta2) distribution for anchor (discretized)
#returns alphaLOO, p0, best_loo that optimizes loo error
function loo_betaAnchor(xs, cs, mhats, alpha_grid, theta2_grid, mu_grid; info=false)
	alphaLOO = 0.
	theta1LOO = -Inf
	theta2LOO = -Inf
	best_val = Inf
	d = size(mhats, 1)
	p0 = zeros(d)

	for theta2 in theta2_grid
		#theta1 = mu/(1-mu) * theta2 
		#since mu in [0, 1] we search a scaled grid
		for mu in mu_grid
			theta1 = mu / (1-mu) * theta2 

			#form p0
			formBetaAnchor!(theta1, theta2, d, p0)

			for alpha in alpha_grid 
				out = zLOObar_unsc(xs, cs, mhats, (p0, alpha))
				if out < best_val			
					alphaLOO = alpha
					theta1LOO = theta1
					theta2LOO = theta2
					best_val = out
				end
			end #over alpha
		end #over mu  (aka theta1)
	end#over theta 2

    #confirm it does better than mm
    theta1, theta2 = mm_beta_param(get_GM_anchor(mhats))
   	formBetaAnchor!(theta1, theta2, d, p0)
   	alpha, jstar, curve = loo_alpha(xs, cs, mhats, p0, alpha_grid)
   	out = curve[jstar]
   	if out < best_val
   		return alpha, p0, out
   	end

	info && println("theta1Loo:\t", theta1LOO, "\t theta2LOO:\t", theta2LOO, "\tMean:\t", theta1LOO/(theta1LOO + theta2LOO))

	#compute the p0 one more time (hopefully fast)
	formBetaAnchor!(theta1LOO, theta2LOO, d, p0)
	return alphaLOO, p0, best_val
end	

#Fits a beta(theta1, theta2) distribution for anchor (discretized)
#returns alphaOR, p0, perf that optimizes oracle error
function oracle_betaAnchor(xs, cs, mhats, ps, lams, alpha_grid, theta2_grid, mu_grid; info=false)
	alphaOR = 0.
	theta1OR = -Inf
	theta2OR = -Inf
	best_val = Inf
	d = size(mhats, 1)
	p0 = zeros(d)

	for theta2 in theta2_grid
		#theta1 = mu/(1-mu) * theta2 
		#since mu in [0, 1] we search a scaled grid
		for mu in mu_grid
			theta1 = mu / (1-mu) * theta2 

			#form p0
			formBetaAnchor!(theta1, theta2, d, p0)

			for alpha in alpha_grid 
				out = zbar(xs, cs, mhats, ps, lams, (p0, alpha))
				if out < best_val			
					alphaOR = alpha
					theta1OR = theta1
					theta2OR = theta2
					best_val = out

					info && println("alpha\t", alphaOR, "\t theta1Loo:\t", theta1OR, "\t theta2OR:\t", theta2OR, "\tMean:\t", theta1OR/(theta1OR + theta2OR))
				end
			end #over alpha
		end #over mu  (aka theta1)
	end#over theta 2

    #confirm it does better than mm
    theta1, theta2 = mm_beta_param(get_GM_anchor(mhats))
   	formBetaAnchor!(theta1, theta2, d, p0)
   	alpha, jstar, curve = oracle_alpha(xs, cs, mhats, ps, lams, p0, alpha_grid)
   	out = curve[jstar]
   	if out < best_val
   		return alpha, p0, out
   	end

	#compute the p0
	info && println("theta1Loo:\t", theta1OR, "\t theta2OR:\t", theta2OR, "\tMean:\t", theta1OR/(theta1OR + theta2OR))
	formBetaAnchor!(theta1OR, theta2OR, d, p0)
	return alphaOR, p0, best_val
end	


#compute the beta dist param by mm to mean and variance
function mm_beta_param(pGM)
	supp = range(0, stop=1, length=length(pGM))
	mu = dot(pGM, supp)
	var = dot(pGM, supp.^2) - mu^2
	if var > mu * (1 - mu)
		#fail silently
		return (1., 1.)
	end
	v = mu * (1 - mu) / var
	return mu * v, (1 - mu) * v
end


#Fits a beta(theta1, theta2) distribution for anchor (discretized)
#returns alphaLOO, p0, best_loo that optimizes loo error
#uses a black-box optimization routine
function loo_betaAnchor(xs, cs, mhats; info=false, time_limit = 45, iterations=1000, 
						init_alpha=1., init_theta1= 1., init_theta2=1.)

	d = size(mhats, 1)
	p0 = zeros(d) #used as shared storage

	#ys = [alpha, theta1, theta2]
	function f(ys)
		alpha = ys[1]^2
		theta1 = ys[2]^2
		theta2 = ys[3]^2
		#form p0
		formBetaAnchor!(theta1, theta2, d, p0)
		zLOObar_unsc(xs, cs, mhats, (p0, alpha))
	end
	ys1 = [init_alpha, init_theta1, init_theta2]
	info && println("Initial Value:\t", f(ys1))
    t= @elapsed results = optimize(f, ys1, 
                    ParticleSwarm(n_particles=40), 
                    Optim.Options(time_limit=time_limit, iterations=iterations))

    z1 = Optim.minimum(results)
    ystar = Optim.minimizer(results)
    info && println("Theta1:\t", ystar[2]^2, "\t Theta2:\t", ystar[3]^2, "\t mu:\t", (ystar[2]^2)/(ystar[2]^2 + ystar[3]^2))
	info && println("Time:\t", t, "\tTime Per Iteration:\t", t/iterations(results))
	formBetaAnchor!(ystar[2]^2, ystar[3]^2, d, p0)

	return ystar[1]^2, p0, z1
end	


#### Helper function for binning data
#dat_vec is vector of actual realizations
#computes a grid of size d
#returns 
	#d vector of lefthand binpoints 
	#d vector of counts
	#raw histogram object for safety
#assumes NA's already filtered from calcualtion
function bin_data(dat_vec, d; TOL = .001)
	#Explicitly make bins to prevent histogram from rounding
	l = minimum(dat_vec)
	u = maximum(dat_vec)
	bin_width = (u - l)/d
    bin_edges = collect(range(l, stop=u, length=d + 1))
    bin_edges[end] += TOL * bin_width  #inflate the last one a little...
    bin_edges[1] -= TOL * bin_width
    dat_hist = fit(Histogram, dat_vec, bin_edges, closed =:left)
    bin_edges[1:d], dat_hist.weights, dat_hist    
end

###Helper function for splitting data for k-fold cross-validation
#This is not a memory efficient implementation
#Just lazy split/iterations
function split_cv(mhats, numFolds)
	d, K = size(mhats)
    Ntot = convert(Int, sum(mhats))
    splits = mod.(1:Ntot, numFolds) .+ 1
    shuffle!(splits)
    cv_data = [zero(mhats) for fold = 1:numFolds]

    #iterate through each k in order
    ix_split = 1

    for k = 1:K
        for i = 1:d
            for j = 1:mhats[i, k]
                cv_data[splits[ix_split]][i, k] += 1
                ix_split += 1            
            end
        end
    end
    return cv_data
end



