function solve_ode_filepath = WriteMatlabSolver(model,varargin)
%WRITEMATLABSOLVER - write m-file that numerically inteegrates the model
%
% Usage:
%   filepath = WriteMatlabSolver(model,varargin)
%
% Inputs:
%   - model: DynaSim model structure (see GenerateModel)
%   - options:
%     'tspan'         : units must be consistent with dt and equations
%                       {[beg,end]} (default: [0 100])
%     'ic'            : initial conditions; this overrides definition in model structure
%     'solver'        : DynaSim and built-in Matlab solvers
%                       {'euler','rk2','rk4','modifiedeuler',
%                       'ode23','ode45','ode15s','ode23s'}
%     'matlab_solver_options': options from odeset for use with built-in Matlab solvers
%     'dt'            :  time step used for fixed step DSSim solvers (default: 0.01)
%     'modifications' : DynaSim modifications structure
%     'reduce_function_calls_flag': whether to eliminate internal function
%                                   calls {0 or 1} (default: 1)
%     'coder_flag'    : whether to compile using coder instead of interpreting
%                       Matlab (default: exist('codegen')==6 TODO is this correct?
%                       what does this mean?)
%     'downsample_factor': downsampling applied during simulation. Only every
%                          downsample_factor-time point is stored in memory or
%                          written to disk (default: 1)
%     'random_seed'   : seed for random number generator (usage:
%                       rng(random_seed)) (default: now)
%
% Outputs:
%   - filepath (solve_ode.m)
%   - odefun_filepath (solve_ode_odefun.m)
%
% Dependencies: CheckOptions, CheckModel
%
% See also: SimulateModel, dynasim2odefun

% Check inputs
options=CheckOptions(varargin,{...
  'ic',[],[],...                  % initial conditions (overrides definition in model structure)
  'tspan',[0 100],[],...          % [beg,end] (units must be consistent with dt and equations)
  'dt',.01,[],...                 % time step used for fixed step DynaSim solvers
  'downsample_factor',1,[],...    % downsampling applied after simulation (only every downsample_factor-time point is returned)
  'random_seed','shuffle',[],...        % seed for random number generator (usage: rng(random_seed))
  'solver','euler',{'ode23','ode45','ode1','ode2','ode3','ode4','ode5','ode8',...
    'ode113','ode15s','ode23s','ode23t','ode23tb'},... % DSSim and built-in Matlab solvers
  'solver_type','matlab',{'matlab', 'matlab_no_mex'},... % if compile_flag==1, will decide whether to mex solve_file or odefun_file
  'matlab_solver_options',[],[],... % options from odeset for use with built-in Matlab solvers
  'reduce_function_calls_flag',1,{0,1},...   % whether to eliminate internal (anonymous) function calls
  'save_parameters_flag',1,{0,1},...
  'filename',[],[],...         % name of solver file that integrates model
  'fileID',1,[],...
  'compile_flag',exist('codegen')==6,{0,1},... % whether to prepare script for being compiled using coder instead of interpreting Matlab
  'verbose_flag',1,{0,1},...
  },false);

% Check inputs
model=CheckModel(model); 

% convert matlab solver options from key/value to struct using odeset if necessary
if iscell(options.matlab_solver_options) && ~isempty(options.matlab_solver_options)
  options.matlab_solver_options = odeset(options.matlab_solver_options{:});
end

%% 1.0 Get ode_fun

% create function that calls feval(@solver,...) and has subfunction
% defining odefun (including optional conditionals)...

[odefun,IC,elem_names]=dynasim2odefun(PropagateParameters(PropagateFunctions(model)), 'odefun_output','func_body');
% FIXME: remove netcons

%% 2.0 prepare model info
parameter_prefix='p.';%'pset.p.';
state_variables=model.state_variables;

% 1.1 eliminate internal (anonymous) function calls from model equations
% if options.reduce_function_calls_flag==1
  model=PropagateFunctions(model);
% end

% 1.1 prepare parameters
if options.save_parameters_flag
  % add parameter struct prefix to parameters in model equations
  model=PropagateParameters(model,'action','prepend','prefix',parameter_prefix);
  
  % set and capture numeric seed value
  if options.compile_flag==1
    % todo: make seed string (eg, 'shuffle') from param struct work with coder (options.compile_flag=1)
    % (currently raises error: "String input must be constant")
    % workaround: (shuffle here and get numeric seed for MEX-compatible params.mat)
    rng(options.random_seed);
    options.random_seed=getfield(rng,'Seed');  % <-- current active seed
  end
  
  % set parameter file name (save with m-file)
  [fpath,fname,fext]=fileparts(options.filename);
  odefun_filename = [fname '_odefun'];
  param_file_name = fullfile(fpath,'params.mat');
  
  % save parameters to disk
  warning('off','catstruct:DuplicatesFound');
  
  p=catstruct(CheckSolverOptions(options),model.parameters);
  if options.verbose_flag
    fprintf('saving params.mat\n');
  end
  
%   % add inital conditions
%   if isempty(options.ic)
%     p.ic = IC;
%   else %if overridden from options
%     p.ic = options.ic;
%   end

  save(param_file_name,'p');
else
  % insert parameter values into model expressions
  model=PropagateParameters(model,'action','substitute');
end

% 1.2 prepare list of outputs (state variables and monitors)
tmp=cellfun(@(x)[x ','],model.state_variables,'uni',0);
tmp=[tmp{:}];
output_string=tmp(1:end-1);

if ~isempty(model.monitors)
  tmp=cellfun(@(x)[x ','],fieldnames(model.monitors),'uni',0);
  tmp=[tmp{:}];
  output_string=[output_string ',' tmp(1:end-1)];
end

if ~isempty(model.fixed_variables)
  tmp=cellfun(@(x)[x ','],fieldnames(model.fixed_variables),'uni',0);
  tmp=[tmp{:}];
  output_string=[output_string ',' tmp(1:end-1)];
end

output_string=['[T,' output_string ']']; % state vars, monitors, time vector

% HACK to get IC to work
if options.downsample_factor == 1
  for fieldNameC = fieldnames(model.ICs)'
    model.ICs.(fieldNameC{1}) = regexprep(model.ICs.(fieldNameC{1}), '_t0', '(1,:)');
  end
end


%% 3.0 write m-file solver
% 2.1 create mfile
if ~isempty(options.filename)
  if options.verbose_flag
    fprintf('Creating solver file: %s\n',options.filename);
  end
  
  fid=fopen(options.filename,'wt');
else
  fid=options.fileID;
end

% get abs file path
solve_ode_filepath = fopen(fid);


fprintf(fid,'function %s=solve_ode\n',output_string);

% 2.3 load parameters
if options.save_parameters_flag
  fprintf(fid,'\n%% ------------------------------------------------------------\n');
  fprintf(fid,'%% Parameters:\n');
  fprintf(fid,'%% ------------------------------------------------------------\n');
  fprintf(fid,'p=load(''params.mat'',''p''); p=p.p;\n');
end

% write tspan, dt, and downsample_factor
if options.save_parameters_flag
  fprintf(fid,'downsample_factor = %sdownsample_factor;\n',parameter_prefix);
  fprintf(fid,'dt = %sdt;\n',parameter_prefix);
  fprintf(fid,'T = (%stspan(1):downsample_factor*dt:%stspan(2))'';\n',parameter_prefix,parameter_prefix);
else
  fprintf(fid,'tspan=[%g %g];\ndt = %g;\ndownsample_factor = %g;\n',options.tspan,options.dt,options.downsample_factor);
  fprintf(fid,'T = (tspan(1):downsample_factor*dt:tspan(2))'';\n');
end
  % NOTE: T is different here since we take into account downsampling

% write calculation of time vector and derived parameters: ntime, nsamp
fprintf(fid,'ntime=length(T);\nnsamp=length(1:downsample_factor:ntime);\n');

% 2.4 evaluate fixed variables
if ~isempty(model.fixed_variables)
  fprintf(fid,'\n%% ------------------------------------------------------------\n');
  fprintf(fid,'%% Fixed variables:\n');
  fprintf(fid,'%% ------------------------------------------------------------\n');
  names=fieldnames(model.fixed_variables);
  expressions=struct2cell(model.fixed_variables);
  for i=1:length(names)
    fprintf(fid,'%s = %s;\n',names{i},expressions{i});
  end
end

% 2.5 evaluate function handles
if ~isempty(model.functions) && options.reduce_function_calls_flag==0
  fprintf(fid,'\n%% ------------------------------------------------------------\n');
  fprintf(fid,'%% Functions:\n');
  fprintf(fid,'%% ------------------------------------------------------------\n');
  names=fieldnames(model.functions);
  expressions=struct2cell(model.functions);
  for i=1:length(names)
    fprintf(fid,'%s = %s;\n',names{i},expressions{i});
  end
end

% 2.6 prepare storage
fprintf(fid,'\n%% ------------------------------------------------------------\n');
fprintf(fid,'%% Initial conditions:\n');
fprintf(fid,'%% ------------------------------------------------------------\n');

% 2.2 set random seed
fprintf(fid,'%% seed the random number generator\n');
if options.save_parameters_flag
  fprintf(fid,'rng(%srandom_seed);\n',parameter_prefix);
else  
  if ischar(options.random_seed)
    fprintf(fid,'rng(''%s'');\n',options.random_seed);
  elseif isnumeric(options.random_seed)
    fprintf(fid,'rng(%g);\n',options.random_seed);
  end
end

%% evaluate fixed_variables
%?

%% Numerical integration
% write code to do numerical integration
fprintf(fid,'%% ###########################################################\n');
fprintf(fid,'%% Numerical integration:\n');
fprintf(fid,'%% ###########################################################\n');

if options.compile_flag && strcmp(options.solver_type,'matlab_no_mex')
  odefun_str_name = odefun_filename;
else
  odefun_str_name = 'odefun';
end

if ~isempty(options.matlab_solver_options)
  fprintf(fid,'[time,data] = %s(@%s, T, p.ic, p.matlab_solver_options);\n', options.solver, odefun_str_name);
else
  fprintf(fid,'[time,data] = %s(@%s, T, p.ic);\n', options.solver, odefun_str_name);
end

%% Get vars from odefun output
fprintf(fid,'\n%%Extract linear data into original state variables\n');

% evaluate ICs to get (# elems) per state var and set up generic state var X
num_vars=length(model.state_variables);
state_var_index=0;
for i=1:num_vars
  var=model.state_variables{i};
  
  % evaluate ICs to get (# elems) per state var
  num_elems=length(eval([model.ICs.(var) ';']));
  
  % set state var indices a variables for generic state vector X
  data_inds = state_var_index + [1,num_elems];
  
  assert(strcmp(elem_names{data_inds(1)}, var)) %current elem should be same as var
  
  fprintf(fid,'%s = data(%i:%i,:)'';\n', var, data_inds(1), data_inds(end)); %make sure to transpose so time is 1st dim
  
  state_var_index = state_var_index + num_elems;
end

%% fprintf end for solve function
fprintf(fid,'\nend\n\n');

%% ODEFUN
if options.compile_flag && strcmp(options.solver_type,'matlab_no_mex') % save ode function as separate m-file for mex compilation
  %open file
  odefun_filepath = fullfile(fpath, [odefun_filename fext]);
  odefun_fid = fopen(odefun_filepath,'wt');
  
  %write to file
  fprintf(odefun_fid,'function dydt = %s(t,X)\n', odefun_filename);
%   if isempty(regexp(odefun,'[^a-zA-Z]t[^a-zA-Z]','once'))
    fprintf(odefun_fid, 'assert(isa(t, ''double''));');
%   end
  fprintf(odefun_fid, 'assert(isa(X, ''double''));');
  fprintf(odefun_fid,'  dydt = %s;\n', odefun);
  fprintf(odefun_fid,'end\n');
  
  %close file
  fclose(odefun_fid);
  
  %% mex compile odefun
  PrepareMEX(odefun_filepath);
  
else %use subfunction
  fprintf(fid,'\n%% ###########################################################\n');
  fprintf(fid,'%% SUBFUNCTIONS\n');
  fprintf(fid,'%% ###########################################################\n\n');
  
  % make sub function (no shared variables with main function workspace for max performance)
  fprintf(fid,'function dydt = odefun(t,X)\n');
  fprintf(fid,'  dydt = %s;\n', odefun);
  fprintf(fid,'end\n');
end

if ~strcmp(solve_ode_filepath,'"stdout"')
  fclose(fid);
  % wait for file before continuing to simulation
  while ~exist(solve_ode_filepath,'file')
    pause(.01);
  end
end

end %function
%% END MAIN FUNC