# Coverage is opt-in so the normal fast test loop remains unchanged.
SimpleCov.configure do
  cover "lib/**/*.rb"
  enable_coverage :branch
end
