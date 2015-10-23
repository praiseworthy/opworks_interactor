Gem::Specification.new do |s|
  s.name        = 'opsworks_interactor'
  s.version     = '0.0.2'
  s.date        = '2015-10-22'
  s.summary     = 'Easily do zero-downtime deploys on Amazon Opsworks'
  s.description = 'A ruby class that allows concurrent-safe, synchronized, zero-downtime rolling deploys to servers running on Amazon Opsworks'
  s.authors     = ['Sam Davies']
  s.email       = 'seivadmas@gmail.com'
  s.files       = ['lib/opsworks_interactor.rb']
  s.homepage    = 'https://github.org/fosubo/opworks_interactor'
  s.license     = 'MIT'
  s.add_runtime_dependency 'aws-sdk', ['~> 2']
end
