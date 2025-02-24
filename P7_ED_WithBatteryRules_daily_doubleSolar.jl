using JuMP
using Ipopt
using Gurobi
using MAT
using Plots
using Interpolations

# Optimization code updated for daily optimization with value updates for the next day.

# Shungnak_data = matread("/Users/jyadav/UVM_Research_Work/Documents/Alaska_Community_data/Shungnak_1.mat")
Shungnak_data = matread("/Users/jyadav/UVM_Research_Work/Julia_Examples/HeatPumpScheduling/Results_usedInPaper/LoadData_smartHPs_Shungnak_ToutLimits.mat")
# Pd = Shungnak_data["data"][1:52560, 1] / 1000  # demand in kW
# Ppv = Shungnak_data["data"][1:52560, 2] / 1000  # PV generation in kW
# Pd = Shungnak_data["data_with_18k_vfd_dumb"][:, 3] / 1000  # demand in kW
# Ppv = Shungnak_data["data_with_18k_vfd_dumb"][:, 2] / 1000  

Pd = Shungnak_data["data_with_12k_vfd_smart_minus10"][:, 3] / 1000  # demand in kW
Ppv = 2*Shungnak_data["data_with_12k_vfd_smart_minus10"][:, 2] / 1000

Shungnak_2023_temp = matread("/Users/jyadav/UVM_Research_Work/Julia_Examples/HeatPumpScheduling/Shungnak_temp_historicData_Julia.mat")
min = 0:60:24*60*365  # 60 minutes data for 365 days
min_new = 0:10:24*60*365-1  # 10 min data
interp_func = linear_interpolation(min, Shungnak_2023_temp["Shungnak_temp_yearly"][:,1]);
Tout_interp = interp_func.(min_new) .* 9 / 5 .+ 32;

Pgmax = 1.500  # kW, max generator capacity
Pgmin = 0    # min generator capacity
Pb_max = 0.250*3#*3 # kWh, max battery capacity
SOC_max = 0.98
SOC_min = 0.20
battery_capacity = 0.380*3.4  # kWh
eta_charge = 0.95
eta_discharge = 0.95
dt = 1/6;  # time step in hours
M = 1e6  # Big M constant for linearization

# SOC_initial = 0.59  # Starting state of charge

Pg_results = []
Pbch_results = []
Pbdch_results = []
SOC_results = []
Cost_results = []
num_time_steps_above_30_expr = []
Pd_results = []
Ppv_results = []

for day in 1:365#[1:85; 87:365]
    γ = 0.1;α = 700;
    start_time = (day - 1) * 144 + 1  # 144 time steps per day
    end_time = day * 144  # End time of the day

    model = Model(Gurobi.Optimizer)
    @variable(model, Pg[start_time:end_time] >= 0, upper_bound = Pgmax)  # Generator power
    @variable(model, Pb_ch[start_time:end_time] >= 0, upper_bound = Pb_max)  # Battery charging power
    @variable(model, Pb_dch[start_time:end_time] >= 0, upper_bound = Pb_max)  # Battery discharging power
    @variable(model, SOC[start_time:end_time+1])  # State of charge
    @variable(model, z_ch[start_time:end_time], Bin)  # Binary variable for charging state
    @variable(model, z_dch[start_time:end_time], Bin)  # Binary variable for discharging state
    @variable(model, z_tout[start_time:end_time], Bin)  # Binary variable for temperature condition
    @variable(model, z_idle[start_time:end_time], Bin)  # Binary variable for idle state

    # Initial condition for SOC
    if day ==1
        SOC_initial = 0.59;
    end
    @constraint(model, SOC[start_time] == SOC_initial)

    total_charging_day = @expression(model, sum(Pb_ch[start_time:end_time]))  # Total daily charging energy
    total_discharging_day = @expression(model, sum(Pb_dch[start_time:end_time]))  # Total daily discharging energy
    num_time_steps_above_30 = @expression(model, sum(z_tout[start_time:end_time]))
    push!(num_time_steps_above_30_expr, num_time_steps_above_30)

    for t in start_time:end_time
        @constraint(model, Pd[t] + Pb_ch[t] - Pb_dch[t] == Ppv[t] + Pg[t])
        @constraint(model, SOC[t+1] == SOC[t] - (Pb_dch[t] / eta_discharge) * dt / battery_capacity + (eta_charge * Pb_ch[t]) * dt / battery_capacity - 0.000 * SOC[t] * (1 - z_idle[t]))
        @constraint(model, SOC_min <= SOC[t] <= SOC_max)
        @constraint(model, Pb_ch[t] <= Pb_max * z_ch[t])  # Complementarity constraint for charging
        @constraint(model, Pb_dch[t] <= Pb_max * z_dch[t])  # Complementarity constraint for discharging
        @constraint(model, z_ch[t] + z_dch[t] + z_idle[t] == 1)  # Battery can either charge, discharge, or be idle

        # @constraint(model, Tout_interp[t] - 40 <= M * z_tout[t])
        # @constraint(model, 40 - Tout_interp[t] <= M * (1 - z_tout[t]))
        # @constraint(model, Pb_ch[t] <= Pb_max * z_tout[t] + M * (1 - z_tout[t]))
        # @constraint(model, Pb_dch[t] <= Pb_max * z_tout[t] + M * (1 - z_tout[t]))
    end

    # min_Tout_day = minimum(Tout_interp[start_time:end_time])
    # if min_Tout_day >= 40
    #     @constraint(model, total_charging_day * eta_charge / 6 >= battery_capacity * (num_time_steps_above_30 / 144))
    #     @constraint(model, total_discharging_day * eta_discharge / 6 >= battery_capacity * (num_time_steps_above_30 / 144))
    # end

    # @constraint(model, SOC[end_time + 1] == SOC[start_time])  # SOC should return to the starting value

    # @objective(model, Min, 700*sum(Pg[t] for t in start_time:end_time))
    @objective(model, Min, α * sum(Pg[t] for t in start_time:end_time) + γ * sum((Pg[t+1] - Pg[t])^2 for t in start_time:end_time-1))


    optimize!(model)

    SOC_initial = value(SOC[end_time])  # Update SOC for the next day

    # Store results in temporary local variables and convert to arrays compatible with MATLAB
    Pg_day_result = Array(value.(Pg[start_time:end_time])*1000)
    Pbch_day_result = Array(value.(Pb_ch[start_time:end_time])*1000)
    Pbdch_day_result = Array(value.(Pb_dch[start_time:end_time])*1000)
    SOC_day_result = Array(value.(SOC[start_time:end_time]))
    Pd_day = Array(Pd[start_time:end_time]*1000)
    Ppv_day = Array(Ppv[start_time:end_time]*1000)
    Cost_day_result = objective_value(model)

    # Append local results to global arrays
    push!(Pg_results, Pg_day_result)
    push!(Pbch_results, Pbch_day_result)
    push!(Pbdch_results, Pbdch_day_result)
    push!(SOC_results, SOC_day_result)
    push!(Cost_results, Cost_day_result)
    push!(Pd_results, Pd_day)
    push!(Ppv_results, Ppv_day)
end

result_dict = Dict(
    "Pg_daily" => Pg_results,
    "Pbch_daily" => Pbch_results,
    "Pbdch_daily" => Pbdch_results,
    "SOC_daily" => SOC_results,
    "Cost_daily" => Cost_results,
    "Pd_daily" => Pd_results,
    "Ppv_daily" => Ppv_results,
    # "num_time_steps_above_30" => num_time_steps_above_30_expr,
)



matwrite("ED_Shungnak_12k_smart_VSCode__Tlim_minus10_doubleSolar.mat", result_dict)
